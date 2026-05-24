import Foundation
import InfraPrimitives

/// `request_user_input` — let the model pause and request structured input
/// from the user (1-3 short questions with optional 2-3 mutually exclusive
/// choices). Upstream parity (Codex H-18 / P3.4,
/// `codex-rs/core/src/tools/handlers/request_user_input.rs` + `..._spec.rs`).
///
/// Schema (verbatim parity with upstream `create_request_user_input_tool`):
///
///     {
///       "type": "object",
///       "properties": {
///         "questions": {
///           "type": "array",
///           "description": "Questions to show the user. Prefer 1 and do not exceed 3",
///           "items": {
///             "type": "object",
///             "properties": {
///               "id":       {"type": "string", "description": "Stable identifier ... (snake_case)."},
///               "header":   {"type": "string", "description": "Short header label ... (12 or fewer chars)."},
///               "question": {"type": "string", "description": "Single-sentence prompt ..."},
///               "options":  {
///                 "type": "array",
///                 "description": "Provide 2-3 mutually exclusive choices...",
///                 "items": {
///                   "type": "object",
///                   "properties": {
///                     "label": {"type": "string", ...},
///                     "description": {"type": "string", ...}
///                   },
///                   "required": ["label","description"],
///                   "additionalProperties": false
///                 }
///               }
///             },
///             "required": ["id","header","question","options"],
///             "additionalProperties": false
///           }
///         }
///       },
///       "required": ["questions"],
///       "additionalProperties": false
///     }
///
/// Behaviour:
///   * Validates the upstream `RequestUserInputArgs` shape and the
///     non-empty-`options` requirement enforced by
///     `normalize_request_user_input_args` (1-3 questions, every question has
///     a non-empty options list).
///   * Publishes `{questions:[...]}` to `RequestUserInputBus` and BLOCKS on
///     `ask(callId:)` until the host responds. If no subscriber is attached
///     the tool returns a "no user-input channel available" error so the
///     model gets a synchronous failure rather than hanging the turn.
///   * Result: the upstream `RequestUserInputResponse` JSON
///     (`{"answers": {<id>: {"answers": [...]}}}`).
public struct RequestUserInputTool: Tool {
    public let name = "request_user_input"
    /// Serial — the model is asking the user for input, no other tool calls
    /// should be racing while the human is being prompted.
    public let parallelSafe = false

    public var toolDescription: String {
        "Request user input for one to three short questions and wait for the response."
    }

    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"questions":{"type":"array","description":"Questions to show the user. Prefer 1 and do not exceed 3","items":{"type":"object","properties":{"id":{"type":"string","description":"Stable identifier for mapping answers (snake_case)."},"header":{"type":"string","description":"Short header label shown in the UI (12 or fewer chars)."},"question":{"type":"string","description":"Single-sentence prompt shown to the user."},"options":{"type":"array","description":"Provide 2-3 mutually exclusive choices. Put the recommended option first and suffix its label with \"(Recommended)\". Do not include an \"Other\" option in this list; the client will add a free-form \"Other\" option automatically.","items":{"type":"object","properties":{"label":{"type":"string","description":"User-facing label (1-5 words)."},"description":{"type":"string","description":"One short sentence explaining impact/tradeoff if selected."}},"required":["label","description"],"additionalProperties":false}}},"required":["id","header","question","options"],"additionalProperties":false}}},"required":["questions"],"additionalProperties":false}
        """#
    }

    public init() {}

    private struct OptionArg: Decodable {
        var label: String
        var description: String
    }
    private struct QuestionArg: Decodable {
        var id: String
        var header: String
        var question: String
        var options: [OptionArg]?
    }
    private struct Args: Decodable {
        var questions: [QuestionArg]
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "invalid request_user_input arguments",
                              success: false, truncated: false)
        }
        if args.questions.isEmpty {
            return ToolResult(callId: call.callId,
                              output: "request_user_input requires at least one question",
                              success: false, truncated: false)
        }
        if args.questions.count > 3 {
            return ToolResult(callId: call.callId,
                              output: "request_user_input accepts at most three questions",
                              success: false, truncated: false)
        }
        for q in args.questions {
            if (q.options ?? []).isEmpty {
                return ToolResult(callId: call.callId,
                                  output: "request_user_input requires non-empty options for every question",
                                  success: false, truncated: false)
            }
        }

        // No subscriber means there is no host channel to answer the
        // question; failing fast is better than blocking the turn forever.
        let subs = await RequestUserInputBus.shared.subscriptionCount()
        guard subs > 0 else {
            return ToolResult(callId: call.callId,
                              output: "request_user_input is unavailable: no user-input channel attached",
                              success: false, truncated: false)
        }

        let reply = await RequestUserInputBus.shared.ask(
            callId: call.callId, payloadJSON: call.argumentsJSON)
        guard let reply else {
            return ToolResult(callId: call.callId,
                              output: "request_user_input was cancelled before receiving a response",
                              success: false, truncated: false)
        }
        return ToolResult(callId: call.callId, output: reply,
                          success: true, truncated: false)
    }
}
