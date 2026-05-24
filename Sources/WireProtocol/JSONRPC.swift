import Foundation

/// Request id is `string | number` and must round-trip without coercion
/// (port-eval §4.3). Numeric strings stay strings.
public enum RequestId: Hashable, Sendable, Codable {
    case string(String)
    case int(Int64)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Try integer first; a JSON string is never decodable as Int64 so
        // string ids are preserved. (A bare JSON number is an int here.)
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        }
    }
    public var description: String {
        switch self { case .string(let s): return s; case .int(let i): return String(i) }
    }
}

/// Optional W3C trace context carried on requests (`trace`).
public struct W3CTrace: Sendable, Equatable, Codable {
    public var traceparent: String
    public var tracestate: String?
    public init(traceparent: String, tracestate: String? = nil) {
        self.traceparent = traceparent
        self.tracestate = tracestate
    }
}

public struct JSONRPCRequest: Sendable, Equatable {
    public var id: RequestId
    public var method: String
    public var params: JSONValue?
    public var trace: W3CTrace?
    public init(id: RequestId, method: String, params: JSONValue? = nil, trace: W3CTrace? = nil) {
        self.id = id; self.method = method; self.params = params; self.trace = trace
    }
}

public struct JSONRPCNotification: Sendable, Equatable {
    public var method: String
    public var params: JSONValue?
    public init(method: String, params: JSONValue? = nil) {
        self.method = method; self.params = params
    }
}

public struct JSONRPCResponse: Sendable, Equatable {
    public var id: RequestId
    public var result: JSONValue
    public init(id: RequestId, result: JSONValue) {
        self.id = id; self.result = result
    }
}

public struct JSONRPCErrorObject: Sendable, Equatable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }
    enum CodingKeys: String, CodingKey { case code, message, data }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(data, forKey: .data)   // omit-not-null
    }
}

public struct JSONRPCError: Sendable, Equatable {
    public var id: RequestId
    public var error: JSONRPCErrorObject
    public init(id: RequestId, error: JSONRPCErrorObject) {
        self.id = id; self.error = error
    }
}

/// The four-kind union, discriminated **structurally** (no tag, no
/// `jsonrpc` field — port-eval §2.2/§4). Decode tolerates a stray
/// `"jsonrpc"` on input but never emits one.
public enum JSONRPCMessage: Sendable, Equatable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
    case error(JSONRPCError)
}

private struct DynKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    static let id = DynKey(stringValue: "id")
    static let method = DynKey(stringValue: "method")
    static let params = DynKey(stringValue: "params")
    static let result = DynKey(stringValue: "result")
    static let error = DynKey(stringValue: "error")
    static let trace = DynKey(stringValue: "trace")
}

extension JSONRPCMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynKey.self)
        let hasID = c.contains(.id)
        let hasMethod = c.contains(.method)
        let hasResult = c.contains(.result)
        let hasError = c.contains(.error)

        // Structural discrimination. Codex's four message shapes are disjoint
        // (Request: id+method, Notification: method, no id; Response: id+
        // result; Error: id+error), so testing the most specific keys first
        // (error → result → method+id → method) is equivalent to
        // serde(untagged) "first variant that decodes" while being robust to
        // payloads whose `params`/`result` happen to contain overlapping
        // keys. A stray `"jsonrpc"` on input is ignored; it is never emitted.
        if hasError && hasID {
            self = .error(JSONRPCError(
                id: try c.decode(RequestId.self, forKey: .id),
                error: try c.decode(JSONRPCErrorObject.self, forKey: .error)))
        } else if hasResult && hasID {
            self = .response(JSONRPCResponse(
                id: try c.decode(RequestId.self, forKey: .id),
                result: try c.decode(JSONValue.self, forKey: .result)))
        } else if hasMethod && hasID {
            self = .request(JSONRPCRequest(
                id: try c.decode(RequestId.self, forKey: .id),
                method: try c.decode(String.self, forKey: .method),
                params: try c.decodeIfPresent(JSONValue.self, forKey: .params),
                trace: try c.decodeIfPresent(W3CTrace.self, forKey: .trace)))
        } else if hasMethod {
            self = .notification(JSONRPCNotification(
                method: try c.decode(String.self, forKey: .method),
                params: try c.decodeIfPresent(JSONValue.self, forKey: .params)))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: DynKey.method, in: c,
                debugDescription: "not a JSON-RPC message (no method/result/error)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynKey.self)
        switch self {
        case .request(let r):
            try c.encode(r.id, forKey: .id)
            try c.encode(r.method, forKey: .method)
            try c.encodeIfPresent(r.params, forKey: .params)   // omit-not-null
            try c.encodeIfPresent(r.trace, forKey: .trace)
        case .notification(let n):
            try c.encode(n.method, forKey: .method)
            try c.encodeIfPresent(n.params, forKey: .params)
        case .response(let r):
            try c.encode(r.id, forKey: .id)
            try c.encode(r.result, forKey: .result)
        case .error(let e):
            try c.encode(e.id, forKey: .id)
            try c.encode(e.error, forKey: .error)
        }
        // Intentionally no "jsonrpc" key, ever (port-eval §2.2).
    }
}