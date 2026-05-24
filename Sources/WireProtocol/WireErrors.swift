import Foundation

/// Exact error sentinels from the Codex app-server (port-eval §2.2/§4.6).
/// These strings/codes are a wire contract and must match byte-for-byte.
public enum WireError {
    public static let overloadCode = -32001
    public static let overloadMessage = "Server overloaded; retry later."
    public static let unsupportedCode = -32601
    public static let invalidRequestCode = -32600
    public static let internalCode = -32603
    public static let inputTooLargeCode = -32000

    public static let notInitialized = "Not initialized"
    public static let alreadyInitialized = "Already initialized"

    /// `"<descriptor> requires experimentalApi capability"`.
    public static func experimentalRequired(_ descriptor: String) -> String {
        "\(descriptor) requires experimentalApi capability"
    }

    /// `"<method> is not supported yet"` (the -32601 body Codex returns for
    /// reserved/unimplemented methods).
    public static func notSupportedYet(_ method: String) -> String {
        "\(method) is not supported yet"
    }

    public static func overload(id: RequestId) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(code: overloadCode, message: overloadMessage)))
    }
    public static func unsupported(id: RequestId, method: String) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(code: unsupportedCode, message: notSupportedYet(method))))
    }
    public static func invalidRequest(id: RequestId, _ message: String) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(code: invalidRequestCode, message: message)))
    }
    public static func experimental(id: RequestId, descriptor: String) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(code: invalidRequestCode,
                                                 message: experimentalRequired(descriptor))))
    }
    public static func inputTooLarge(id: RequestId, limit: Int) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(code: inputTooLargeCode,
                                                 message: "input too large (limit \(limit) bytes)")))
    }
    public static func internalError(id: RequestId, _ message: String) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(code: internalCode, message: message)))
    }
}