import Foundation

/// A faithful JSON value. Distinguishes integer vs floating numbers so wire
/// round-trips of protocol payloads do not silently coerce ids/counts.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON value")
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
}

public extension JSONValue {
    var isNull: Bool { if case .null = self { return true }; return false }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    /// Integer view. A `.double` is only treated as an integer when it is
    /// finite, integral, and within Int64 range (avoids surprises on NaN /
    /// infinity / >2^63 doubles built programmatically).
    var intValue: Int64? {
        switch self {
        case .int(let i):
            return i
        case .double(let d):
            guard d.isFinite, d.rounded() == d,
                  d >= -9_223_372_036_854_775_808.0,
                  d <  9_223_372_036_854_775_808.0 else { return nil }
            return Int64(d)
        default:
            return nil
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}