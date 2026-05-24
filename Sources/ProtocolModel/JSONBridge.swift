import Foundation
import WireProtocol

public enum JSONBridge {
    /// Encode any `Encodable` into a `JSONValue` (one structured pass).
    public static func value<T: Encodable>(_ v: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(v)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode a typed value out of a `JSONValue`.
    public static func decode<T: Decodable>(_ type: T.Type, from json: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Decode typed params from an optional `JSONValue` (missing → throws a
    /// readable invalid-params error the dispatcher maps to -32600).
    public static func params<T: Decodable>(_ type: T.Type, from json: JSONValue?) throws -> T {
        guard let json else { throw ProtocolError.invalidParams("Invalid request: missing params") }
        do { return try decode(type, from: json) }
        catch { throw ProtocolError.invalidParams(invalidRequestMessage(for: error)) }
    }

    /// For methods whose params are optional: a missing `params` uses the
    /// supplied default, but a *present-but-malformed* `params` still throws
    /// `invalidParams` (no silent swallowing).
    public static func paramsAllowingEmpty<T: Decodable>(
        _ type: T.Type, from json: JSONValue?, default def: @autoclosure () -> T
    ) throws -> T {
        guard let json else { return def() }
        do { return try decode(type, from: json) }
        catch { throw ProtocolError.invalidParams(invalidRequestMessage(for: error)) }
    }

    private static func invalidRequestMessage(for error: any Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error {
            return "Invalid request: missing field `\(key.stringValue)`"
        }
        if case DecodingError.valueNotFound(_, let context) = error,
           let key = context.codingPath.last {
            return "Invalid request: missing field `\(key.stringValue)`"
        }
        if case DecodingError.typeMismatch(let type, let context) = error,
           let key = context.codingPath.last {
            return "Invalid request: invalid type for field `\(key.stringValue)`; expected \(type)"
        }
        if case DecodingError.dataCorrupted(let context) = error,
           let key = context.codingPath.last {
            return "Invalid request: invalid value for field `\(key.stringValue)`: \(context.debugDescription)"
        }
        return "Invalid request: \(error)"
    }
}

public enum ProtocolError: Error, Sendable, Equatable {
    case invalidParams(String)
    case notInitialized
    case alreadyInitialized
    case unsupported(String)
}
