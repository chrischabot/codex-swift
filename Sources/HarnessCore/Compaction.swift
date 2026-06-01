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

    /// Faithful port of upstream `truncate_middle_with_token_budget`
    /// (`utils/string/src/truncate.rs:15`): truncate the MIDDLE of a UTF-8
    /// string to at most `tokens` approximate tokens, preserving the beginning
    /// and the end, joined by the marker `"…{removed_tokens} tokens truncated…"`
    /// (no surrounding newlines; unit = tokens). `removed_tokens` is
    /// `approx_tokens_from_byte_count(total_bytes - max_bytes)`.
    static func truncateToTokens(_ s: String, _ tokens: Int) -> String {
        if s.isEmpty { return s }
        let maxBytes = approxBytesForTokens(tokens)
        // Upstream early-out: nothing removed when within budget.
        if tokens > 0 && s.utf8.count <= maxBytes { return s }
        return truncateWithByteEstimate(s, maxBytes: maxBytes)
    }

    static func approxBytesForTokens(_ tokens: Int) -> Int { max(0, tokens) * 4 }

    static func approxTokensFromByteCount(_ bytes: Int) -> Int {
        let b = max(0, bytes)
        return (b + 3) / 4
    }

    private static func truncationMarker(removedTokens: Int) -> String {
        "…\(removedTokens) tokens truncated…"
    }

    /// Port of `truncate_with_byte_estimate(.., use_tokens: true)`. Splits the
    /// byte budget in half (left = budget/2, right = budget-left), keeping whole
    /// UTF-8 characters that fit entirely within the prefix/suffix windows.
    private static func truncateWithByteEstimate(_ s: String, maxBytes: Int) -> String {
        if s.isEmpty { return "" }
        let bytes = Array(s.utf8)
        let totalBytes = bytes.count
        if maxBytes == 0 {
            return truncationMarker(removedTokens: approxTokensFromByteCount(totalBytes))
        }
        if totalBytes <= maxBytes { return s }
        let leftBudget = maxBytes / 2
        let rightBudget = maxBytes - leftBudget
        let (prefix, suffix) = splitString(bytes, beginningBytes: leftBudget, endBytes: rightBudget)
        let removed = approxTokensFromByteCount(totalBytes - maxBytes)
        return prefix + truncationMarker(removedTokens: removed) + suffix
    }

    /// Port of `split_string` (truncate.rs): walk the UTF-8 string by character
    /// boundary, keeping a prefix whose bytes end within `beginningBytes` and a
    /// suffix that starts at or after `len - endBytes`.
    private static func splitString(_ bytes: [UInt8], beginningBytes: Int, endBytes: Int) -> (String, String) {
        let len = bytes.count
        if len == 0 { return ("", "") }
        let tailStartTarget = max(0, len - endBytes)
        var prefixEnd = 0
        var suffixStart = len
        var suffixStarted = false
        var idx = 0
        while idx < len {
            let charLen = utf8CharLen(bytes[idx])
            let charEnd = idx + charLen
            if charEnd <= beginningBytes {
                prefixEnd = charEnd
                idx = charEnd
                continue
            }
            if idx >= tailStartTarget {
                if !suffixStarted {
                    suffixStart = idx
                    suffixStarted = true
                }
            }
            idx = charEnd
        }
        if suffixStart < prefixEnd { suffixStart = prefixEnd }
        let before = String(decoding: bytes[0..<prefixEnd], as: UTF8.self)
        let after = String(decoding: bytes[suffixStart..<len], as: UTF8.self)
        return (before, after)
    }

    private static func utf8CharLen(_ first: UInt8) -> Int {
        if first < 0x80 { return 1 }
        if first >= 0xF0 { return 4 }
        if first >= 0xE0 { return 3 }
        if first >= 0xC0 { return 2 }
        return 1 // continuation byte fallback (shouldn't start a char)
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
        // Upstream three-tier `insertion_index` chain
        // (`insert_initial_context_before_last_real_user_or_summary`,
        // compact.rs:419-464): prefer the last real user message, else the last
        // user-like (summary) message, else the last compaction item
        // (`ResponseItem::Compaction | ContextCompaction`, here
        // `.contextCompaction`). Inserting before a trailing compaction item
        // keeps that item last when a remote-compacted history carries only
        // compaction items and no user/summary message.
        var lastCompaction: Int? = nil
        for i in stride(from: h.count - 1, through: 0, by: -1) {
            if case .contextCompaction = h[i] { lastCompaction = i; break }
        }
        if let idx = lastRealUser ?? lastUserOrSummary ?? lastCompaction {
            h.insert(contentsOf: initialContext, at: idx)
        } else {
            h.append(contentsOf: initialContext)
        }
        return h
    }
}