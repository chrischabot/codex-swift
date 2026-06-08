import Foundation

/// A Sendable, Codable JSON value — the mem0 engine's analogue of
/// `serde_json::Value` (Rust) and the project's `ConfigValue`. Memory payloads,
/// metadata, and filters are all `JSONObject` (`[String: JSONValue]`).
public indirect enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: - Accessors

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Numeric coercion to Double across int/double/string (used by range ops).
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    // MARK: - Foundation bridging

    /// Decode a `JSONValue` from raw JSON bytes.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode a `JSONValue` from a JSON string.
    public static func parse(_ string: String) -> JSONValue? {
        parse(Data(string.utf8))
    }

    /// Encode to a compact JSON string (sorted keys for determinism).
    public func jsonString(sortedKeys: Bool = false) -> String {
        let enc = JSONEncoder()
        if sortedKeys { enc.outputFormatting = [.sortedKeys] }
        guard let data = try? enc.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A JSON object — the shape of memory payloads, metadata, and filters.
public typealias JSONObject = [String: JSONValue]

public extension JSONValue {
    /// Convenience constructor for an object.
    static func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }
}