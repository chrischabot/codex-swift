import Foundation

/// Minimal JSON value for the MCP transport (kept local so MCP has no
/// protocol-layer dependency). Parsing and stringification go through Codable
/// / `JSONEncoder` so there is no CoreFoundation dependency and bool vs.
/// number is distinguished correctly on Linux and macOS.
public enum JSONLite: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONLite])
    case object([String: JSONLite])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .number(Double(i)); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONLite].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONLite].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c,
            debugDescription: "unrepresentable JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9.007199254740992e15 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) throws -> JSONLite {
        let dec = JSONDecoder()
        if let v = try? dec.decode(JSONLite.self, from: data) { return v }
        // Top-level fragments: wrap so JSONDecoder accepts scalars too.
        var wrapped = Data("[".utf8); wrapped.append(data); wrapped.append(Data("]".utf8))
        let arr = try dec.decode([JSONLite].self, from: wrapped)
        return arr.first ?? .null
    }

    public static func stringify(_ v: JSONLite) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? enc.encode(v),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
}