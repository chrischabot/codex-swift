import Foundation

/// The CANONICAL vocabulary of chat-template / role / tool / envelope marker NAMES whose
/// presence in untrusted data could break out of a data envelope or hijack a chat template.
///
/// SINGLE SOURCE OF TRUTH. Both prompt-sanitizers consume this list, so the two cannot drift:
/// - `MemoryInfer.ContextSanitizer.breakoutTags` (the remote/MLX prompt path)
/// - `Mem0Core.Mem0Engine.sanitizeForPrompt` PASS-2 attributed-marker pass
///
/// Adding a marker here extends BOTH sanitizers at once. (This module is dependency-free, so
/// it is a safe shared leaf for both `MemoryInfer` and `Mem0Core` — neither imports the other,
/// so a single shared list is the only way to keep their vocabularies identical.)
public enum PromptInjectionVocab {
    public static let markers: [String] = [
        // ChatML / special model control tokens.
        "im_start", "im_end", "endoftext", "eot_id",
        "start_header_id", "end_header_id", "bos", "eos",
        // Conversation roles + common envelope / instruction / tool tags. Includes the
        // canonical Anthropic tool markers (tool_use / tool_result) — the host model family.
        "system", "assistant", "user", "developer",
        "tool", "tool_call", "tool_calls", "tool_use", "tool_result", "tool_response",
        "function", "function_call",
        "context", "instruction", "instructions", "prompt",
        "think", "chat_session", "trajectory", "take", "document",
    ]
}
