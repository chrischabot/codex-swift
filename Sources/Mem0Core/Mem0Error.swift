import Foundation

/// Structured error for the native-Swift mem0 engine. Carries a machine-readable
/// `code` plus an optional `suggestion`, ported from the Rust port's
/// `Mem0Error` taxonomy (`mem0-rs/crates/mem0-core/src/error.rs`) and mem0's
/// Python `exceptions.py`. The REST server maps `kind` → HTTP status.
public struct Mem0Error: Error, Sendable, Equatable, CustomStringConvertible {
    /// The error category (drives HTTP status mapping in the server).
    public enum Kind: String, Sendable, Equatable {
        case validation
        case notFound
        case configuration
        case vectorStore
        case embedding
        case llm
        case database
        case network
        case dependency
        case rateLimit
        case authentication
        case memory
    }

    public var kind: Kind
    public var code: String
    public var message: String
    public var suggestion: String?

    public init(kind: Kind, code: String, message: String, suggestion: String? = nil) {
        self.kind = kind
        self.code = code
        self.message = message
        self.suggestion = suggestion
    }

    public var description: String {
        "[\(code)] \(message)"
    }

    // MARK: - Constructors (mirroring the Rust helpers)

    public static func validation(_ message: String) -> Mem0Error {
        Mem0Error(kind: .validation, code: "VALIDATION", message: message)
    }

    public static func validationCode(_ code: String, _ message: String,
                                      _ suggestion: String? = nil) -> Mem0Error {
        Mem0Error(kind: .validation, code: code, message: message, suggestion: suggestion)
    }

    public static func notFound(_ message: String) -> Mem0Error {
        Mem0Error(kind: .notFound, code: "MEM_404", message: message)
    }

    public static func configuration(_ message: String) -> Mem0Error {
        Mem0Error(kind: .configuration, code: "CFG_001", message: message)
    }

    public static func vectorStore(_ message: String) -> Mem0Error {
        Mem0Error(kind: .vectorStore, code: "VECTOR_001", message: message)
    }

    public static func embedding(_ message: String) -> Mem0Error {
        Mem0Error(kind: .embedding, code: "EMBED_001", message: message)
    }

    public static func llm(_ message: String) -> Mem0Error {
        Mem0Error(kind: .llm, code: "LLM_001", message: message)
    }

    public static func database(_ message: String) -> Mem0Error {
        Mem0Error(kind: .database, code: "DB_001", message: message)
    }

    public static func network(_ message: String) -> Mem0Error {
        Mem0Error(kind: .network, code: "NET_001", message: message)
    }
}

/// Result alias mirroring the Rust port's `Result<T>`.
public typealias Mem0Result<T> = Swift.Result<T, Mem0Error>