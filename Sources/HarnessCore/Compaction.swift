import Foundation
import InfraPrimitives
import ProtocolModel
import Prompts

/// Faithful reproduction of `core/src/compact.rs` deterministic helpers.
///
/// Compaction in Codex is a **model call**: the conversation plus the
/// compaction prompt is streamed and the model's last assistant message
/// becomes the summary suffix. `summary_text = "{SUMMARY_PREFIX}\n{suffix}"`.
/// The replacement history is the most recent user messages (token-bounded to
/// `COMPACT_USER_MESSAGE_MAX_TOKENS`) followed by the summary as a final user
/// message; mid-turn compaction additionally injects initial context before
/// the last real user message. The model-call orchestration lives in
/// `SessionEngine`; everything here is pure and unit-testable.
public enum Compaction {
    public static let summaryPrefix = Templates.compactSummaryPrefix
    public static let compactionPrompt = Templates.compactPrompt
    /// Codex `COMPACT_USER_MESSAGE_MAX_TOKENS`.
    public static let userMessageMaxTokens = 20_000

    /// Codex post-compaction warning (`compact.rs` WarningEvent).
    public static let headsUpWarning =
        "Heads up: Long threads and multiple compactions can cause the model to be less accurate. Start a new thread when possible to keep threads small and targeted."

    /// Controls whether the replacement history re-injects initial context.
    /// Pre-turn/manual compaction uses `.doNotInject`; mid-turn uses
    /// `.beforeLastUserMessage` (Codex `InitialContextInjection`).
    public enum InitialContextInjection: Sendable, Equatable {
        case beforeLastUserMessage
        case doNotInject
    }

    static func approxTokens(_ s: String) -> Int { (s.utf8.count + 3) / 4 }

    /// Codex `is_summary_message`: starts with `"{SUMMARY_PREFIX}\n"`.
    public static func isSummaryMessage(_ message: String) -> Bool {
        message.hasPrefix(summaryPrefix + "\n")
    }

    private static func userText(_ item: ThreadItem) -> String? {
        guard case .userMessage(_, let c) = item else { return nil }
        let t = c.compactMap { $0.text }.joined(separator: "\n")
        return t.isEmpty ? nil : t
    }

    /// Codex `collect_user_messages`: user message texts, excluding prior
    /// compaction summaries.
    public static func collectUserMessages(_ items: [ThreadItem]) -> [String] {
        items.compactMap { item -> String? in
            guard let t = userText(item) else { return nil }
            return isSummaryMessage(t) ? nil : t
        }
    }

    private static func truncateToTokens(_ s: String, _ tokens: Int) -> String {
        let maxBytes = max(4, tokens * 4)
        guard s.utf8.count > maxBytes else { return s }
        var b = HeadTailBuffer(maxBytes: maxBytes)
        b.append(s)
        return b.rendered()
    }

    /// Codex `build_compacted_history`: take the most recent user messages
    /// from the end until the token budget is exhausted (truncating the
    /// boundary message), then append the summary as the final user message.
    public static func buildCompactedHistory(initialContext: [ThreadItem],
                                             userMessages: [String],
                                             summaryText: String,
                                             maxTokens: Int = userMessageMaxTokens) -> [ThreadItem] {
        var history = initialContext
        var selected: [String] = []
        if maxTokens > 0 {
            var remaining = maxTokens
            for message in userMessages.reversed() {
                if remaining == 0 { break }
                let tokens = approxTokens(message)
                if tokens <= remaining {
                    selected.append(message)
                    remaining -= tokens
                } else {
                    selected.append(truncateToTokens(message, remaining))
                    break
                }
            }
            selected.reverse()
        }
        for message in selected {
            history.append(.userMessage(id: ItemId.generate("u"),
                                        content: [UserMessageContent(text: message)]))
        }
        let summary = summaryText.isEmpty ? "(no summary available)" : summaryText
        history.append(.userMessage(id: ItemId.generate("compact"),
                                    content: [UserMessageContent(text: summary)]))
        return history
    }

    /// Codex `insert_initial_context_before_last_real_user_or_summary`:
    /// prefer inserting before the last real (non-summary) user message;
    /// otherwise before the last user-like (summary) message; otherwise
    /// append.
    public static func insertInitialContext(_ history: [ThreadItem],
                                            _ initialContext: [ThreadItem]) -> [ThreadItem] {
        guard !initialContext.isEmpty else { return history }
        var h = history
        var lastUserOrSummary: Int? = nil
        var lastRealUser: Int? = nil
        for i in stride(from: h.count - 1, through: 0, by: -1) {
            guard let t = userText(h[i]) else { continue }
            if lastUserOrSummary == nil { lastUserOrSummary = i }
            if !isSummaryMessage(t) { lastRealUser = i; break }
        }
        if let idx = lastRealUser ?? lastUserOrSummary {
            h.insert(contentsOf: initialContext, at: idx)
        } else {
            h.append(contentsOf: initialContext)
        }
        return h
    }
}