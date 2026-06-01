import Foundation

/// Exact error sentinels from the Codex app-server (port-eval §2.2/§4.6).
/// These strings/codes are a wire contract and must match byte-for-byte.
public enum WireError {
    public static let overloadCode = -32001
    /// `OVERLOADED_ERROR_CODE` (-32001) message.
    ///
    /// INTENTIONAL DIVERGENCE (audit unit "misc"): upstream emits this code
    /// ONLY from the in-process embedder's bounded mpsc queue
    /// (`app-server/src/in_process.rs:547-550,631-634`), with the path-specific
    /// strings "in-process app-server request queue is full" /
    /// "in-process server request queue is full". The Swift port is a
    /// multi-process JSON-RPC server with NO in-process transport; it reuses
    /// -32001 for its own session-admission DoS hardening (see
    /// `RequestRouter` `supervisor.atCapacity()`), a deliberate, test-backed
    /// divergence (AuthGatingAdversarialTests.testSessionFloodAdmissionControl).
    /// A conformant frontend branches on the numeric code -32001, not on the
    /// human-readable message, so this transport-neutral text is kept.
    public static let overloadMessage = "Server overloaded; retry later."
    public static let unsupportedCode = -32601
    public static let invalidRequestCode = -32600
    public static let internalCode = -32603
    public static let inputTooLargeCode = -32000
    /// JSON-RPC `invalid_params` code, used by upstream for the v2
    /// input-length guard (`turn/start`, `turn/steer`).
    public static let invalidParamsCode = -32602
    /// Upstream `MAX_USER_INPUT_TEXT_CHARS` (`protocol/src/user_input.rs`):
    /// `1 << 20` characters across all text input items.
    public static let maxUserInputTextChars = 1 << 20
    /// Upstream `INPUT_TOO_LARGE_ERROR_CODE` (`app-server/src/error_code.rs`).
    public static let inputTooLargeErrorCode = "input_too_large"

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

    /// Upstream v2 input-length guard (`turn_processor::input_too_large_error`):
    /// an `invalid_params` (-32602) carrying
    /// `data: {input_error_code, max_chars, actual_chars}`. The message is
    /// `"Input exceeds the maximum length of <max> characters."`.
    public static func inputTooLargeV2(id: RequestId, actualChars: Int) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(
            code: invalidParamsCode,
            message: "Input exceeds the maximum length of \(maxUserInputTextChars) characters.",
            data: .object([
                "input_error_code": .string(inputTooLargeErrorCode),
                "max_chars": .int(Int64(maxUserInputTextChars)),
                "actual_chars": .int(Int64(actualChars)),
            ]))))
    }
    public static func internalError(id: RequestId, _ message: String) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(code: internalCode, message: message)))
    }

    /// Upstream `config_write_error` (request_processors/config_processor.rs):
    /// an `invalid_request` (-32600) carrying `data: {config_write_error_code:
    /// <camelCase ConfigWriteErrorCode>}`. Code is one of
    /// `configLayerReadonly`, `configVersionConflict`, `configValidationError`,
    /// `configPathNotFound`, `configSchemaUnknownKey`, `userLayerNotFound`.
    public static func configWriteError(id: RequestId, code: String,
                                        _ message: String) -> JSONRPCMessage {
        .error(JSONRPCError(id: id, error: .init(
            code: invalidRequestCode, message: message,
            data: .object(["config_write_error_code": .string(code)]))))
    }
}