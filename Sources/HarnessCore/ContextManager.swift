import Foundation
import InfraPrimitives
import ProtocolModel
import ModelClient

/// In-memory conversation transcript with Codex-faithful token accounting.
///
/// Mirrors `core/src/context_manager/history.rs`:
/// - per-item token estimate = ceil(model-visible bytes / 4) where
///   model-visible bytes is the JSON-serialized item length
///   (`estimate_response_item_model_visible_bytes` +
///   `approx_tokens_from_byte_count`); plus base-instruction tokens.
/// - `totalTokenUsage()` = last server-reported total tokens + estimate of
///   items recorded locally **after the last model-generated item** — this is
///   the value Codex's auto-compact ladder (`get_total_token_usage`) compares
///   against `auto_compact_token_limit`, not the raw whole-history estimate.
/// - tool/command outputs are truncated **on record** at policy*1.2
///   (`record_items` → `truncate_function_output_payload`).
/// - `history_version` is bumped on every rewrite (replace / removeLast /
///   drop-last-N) exactly like Codex.
public struct ContextManager: Sendable {
    public private(set) var history: [ThreadItem] = []
    public private(set) var historyVersion: UInt64 = 0
    /// Last server-reported total token count (`ResponseEvent.completed`).
    public private(set) var lastServerTotalTokens: Int = 0
    /// Base-instructions text contributes to the estimate (Codex
    /// `estimate_token_count` adds `approx_token_count(base_instructions)`).
    public var baseInstructions: String = ""

    public init() {}

    // ceil(bytes / 4) — `approx_tokens_from_byte_count_i64`.
    static func tokensFromBytes(_ bytes: Int) -> Int { (max(0, bytes) + 3) / 4 }

    /// JSON-serialized byte length — `estimate_response_item_model_visible_bytes`
    /// (our item model has no encrypted reasoning/image-data-URL cases, so the
    /// raw serialized size is the model-visible size).
    static func modelVisibleBytes(of item: ThreadItem) -> Int {
        (try? JSONEncoder().encode(item))?.count ?? 0
    }
    static func estimateItemTokens(_ item: ThreadItem) -> Int {
        tokensFromBytes(modelVisibleBytes(of: item))
    }

    /// Codex `is_model_generated_item`: assistant message or reasoning.
    /// `.contextCompaction` is a structural marker (not model-generated
    /// content) so it does not gate `itemsAfterLastModelGenerated`.
    private static func isModelGenerated(_ item: ThreadItem) -> Bool {
        switch item {
        case .agentMessage, .reasoning: return true
        case .userMessage, .commandExecution, .fileChange, .contextMessage,
             .contextCompaction, .unknown: return false
        }
    }
    /// Codex `is_user_turn_boundary`: a (non-contextual) user message.
    private static func isUserTurnBoundary(_ item: ThreadItem) -> Bool {
        if case .userMessage = item { return true }
        return false
    }

    /// Whole-history estimate (base instructions + every item). Used by tests
    /// and diagnostics; the compaction trigger uses `totalTokenUsage()`.
    public var estimatedTokens: Int {
        let base = Self.tokensFromBytes(baseInstructions.utf8.count)
        let items = history.reduce(0) { $0 + Self.estimateItemTokens($1) }
        return base + items
    }

    /// Codex `items_after_last_model_generated_item`
    /// (`core/src/context_manager/history.rs:298`).
    ///
    /// When the history contains no model-generated item (Rust uses
    /// `rposition(...).map_or(items.len(), |i| i+1)`), the start index becomes
    /// `items.len()` and the returned slice is **empty**, not the whole
    /// history. This invariant is load-bearing for post-compaction token
    /// accounting: a freshly compacted history contains only user-role items
    /// (synthesized summary + interleaved user turns) and therefore has no
    /// model-generated boundary. Returning the whole slice would re-add every
    /// item's estimate on top of a stale `lastServerTotalTokens`, producing
    /// the inflated `tokensAfter` value that previously surfaced in the
    /// `.compacted` rollout record. Returning `history[endIndex...]` matches
    /// Rust exactly: an empty slice in the no-model-gen case.
    func itemsAfterLastModelGenerated() -> ArraySlice<ThreadItem> {
        if let idx = history.lastIndex(where: { Self.isModelGenerated($0) }) {
            return history[history.index(after: idx)...]
        }
        return history[history.endIndex...]
    }

    /// Codex `Session::recompute_token_usage`
    /// (`core/src/session/mod.rs:2960`): after a wholesale history rewrite
    /// (compaction), re-baseline the cached server-reported total to the
    /// whole-history estimate — `base_instructions_tokens + sum(item tokens)`
    /// — and zero the per-call delta. Upstream then emits a `TokenCount`
    /// event; the corresponding emit happens at the caller (SessionEngine)
    /// because `ContextManager` is wire-agnostic.
    ///
    /// Returns the new estimated total so the caller can both persist it
    /// (`.compacted.tokensAfter`) and publish it (`tokenUsageUpdated`).
    @discardableResult
    public mutating func recomputeTokenUsage() -> Int {
        let estimate = max(0, estimatedTokens)
        lastServerTotalTokens = estimate
        return estimate
    }

    /// Codex `get_total_token_usage` (server_reasoning_included=true for our
    /// model: there are no client-side encrypted reasoning items to re-add).
    public func totalTokenUsage() -> Int {
        let after = itemsAfterLastModelGenerated()
            .reduce(0) { $0 + Self.estimateItemTokens($1) }
        return lastServerTotalTokens + after
    }

    public mutating func setLastServerTotalTokens(_ t: Int) {
        lastServerTotalTokens = max(0, t)
    }

    public mutating func load(_ items: [ThreadItem]) {
        history = items
        lastServerTotalTokens = 0
    }

    private static func truncate(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var b = HeadTailBuffer(maxBytes: max(16, maxBytes))
        b.append(s)
        return b.rendered()
    }

    /// `record_items`: tool/command outputs are truncated on record at
    /// policy*1.2. `maxOutputBytes == nil` records verbatim (non-output items).
    public mutating func appendItem(_ item: ThreadItem, maxOutputBytes: Int? = nil) {
        switch (item, maxOutputBytes) {
        case (.commandExecution(let id, let cmd, let cwd, let st, let out, let ec), .some(let cap)):
            let budget = Int(Double(cap) * 1.2)
            let truncated = out.map { Self.truncate($0, maxBytes: budget) }
            history.append(.commandExecution(id: id, command: cmd, cwd: cwd, status: st,
                                             aggregatedOutput: truncated, exitCode: ec))
        default:
            history.append(item)
        }
    }

    public mutating func appendUser(_ input: [TurnInput]) {
        let content = input.map { i -> UserMessageContent in
            var c = UserMessageContent(text: i.text ?? "")
            c.type = i.type; c.url = i.url; c.path = i.path
            return c
        }
        history.append(.userMessage(id: ItemId.generate("u"), content: content))
    }

    public mutating func appendAssistant(_ text: String, id: ItemId) {
        history.append(.agentMessage(id: id, text: text))
    }

    /// Codex `replace`: wholesale history rewrite (compaction / rollback);
    /// bumps `history_version`. Returns the new whole-history estimate.
    @discardableResult
    public mutating func replace(_ items: [ThreadItem]) -> Int {
        history = items
        historyVersion &+= 1
        return estimatedTokens
    }

    /// Codex `remove_first_item`: drop the oldest item (used by the
    /// context-window-exceeded compaction trim loop) and also remove its
    /// corresponding call/output counterpart so the invariant that every
    /// tool-call is followed by its tool-output (and vice versa) is preserved.
    ///
    /// Mirrors `core/src/context_manager/history.rs:160` —
    /// ```text
    /// // Remove the oldest item (front of the list). Items are ordered from
    /// // oldest → newest, so index 0 is the first entry recorded.
    /// let removed = self.items.remove(0);
    /// // If the removed item participates in a call/output pair, also remove
    /// // its corresponding counterpart to keep the invariants intact without
    /// // running a full normalization pass.
    /// normalize::remove_corresponding_for(&mut self.items, &removed);
    /// ```
    ///
    /// Our `ThreadItem` model unifies a call and its output into a single
    /// `.commandExecution` entry, but if history ever contains a split
    /// representation (e.g. an in-progress `.commandExecution` with
    /// `aggregatedOutput == nil` followed by a completed one sharing the same
    /// `ItemId`), both halves are now removed together. Returns the number of
    /// items removed: 0 for an empty history, 1 for a singleton/orphan-free
    /// removal, 2 when a paired call/output was removed.
    @discardableResult
    public mutating func removeFirstItem() -> Int {
        guard !history.isEmpty else { return 0 }
        let removed = history.removeFirst()
        let pairRemoved = removeCorrespondingFor(removed)
        return pairRemoved ? 2 : 1
    }

    /// Codex `normalize::remove_corresponding_for` (Swift variant).
    ///
    /// In upstream, function calls and outputs are distinct `ResponseItem`
    /// variants paired by `call_id`. Our `ThreadItem` model uses a single
    /// `.commandExecution` case per tool invocation, identified by `ItemId`.
    /// If history still contains another `.commandExecution` whose id matches
    /// the just-removed entry — i.e. the missing half of a split call/output
    /// pair — that counterpart is removed as well. Other item kinds
    /// (`agentMessage`, `reasoning`, `userMessage`, `fileChange`,
    /// `contextMessage`) have no pair and yield `false`.
    @discardableResult
    private mutating func removeCorrespondingFor(_ item: ThreadItem) -> Bool {
        guard case .commandExecution = item else { return false }
        let targetId = item.id
        if let pos = history.firstIndex(where: {
            if case .commandExecution = $0 { return $0.id == targetId }
            return false
        }) {
            history.remove(at: pos)
            return true
        }
        return false
    }

    /// Codex `remove_last_item` — pop the newest history entry, mirroring
    /// `removeFirstItem`'s orphan-pair handling. If the popped item is half of
    /// a split call/output pair (two `.commandExecution` entries sharing one
    /// `ItemId`), the counterpart is also removed so the "no orphan tool
    /// output" invariant holds after the trim. Returns `true` when at least
    /// one item was removed (`false` only on an empty history).
    @discardableResult
    public mutating func removeLastItem() -> Bool {
        guard !history.isEmpty else { return false }
        let removed = history.removeLast()
        _ = removeCorrespondingFor(removed)
        historyVersion &+= 1
        return true
    }

    /// Codex `drop_last_n_user_turns` (thread/rollback semantics):
    /// - n == 0 → no-op
    /// - no user messages → no-op
    /// - n ≥ user-message count → drop everything from the first user message
    ///   (items recorded before the first user message survive).
    public mutating func dropLastNUserTurns(_ n: Int) {
        guard n > 0 else { return }
        let userPositions = history.indices.filter { Self.isUserTurnBoundary(history[$0]) }
        guard let first = userPositions.first else { return }
        let cut = (n >= userPositions.count) ? first
                                             : userPositions[userPositions.count - n]
        history = Array(history[..<cut])
        historyVersion &+= 1
    }

    /// Project history into model prompt inputs. Faithful to Codex
    /// `for_prompt`: the full chronological transcript (user + assistant +
    /// tool outputs) is sent every request; the server prompt cache keyed by
    /// `prompt_cache_key = threadId` (and WS incremental delta) makes the
    /// re-send cheap. Assistant turns are NOT dropped.
    public func forPrompt(extra: [PromptInput] = []) -> [PromptInput] {
        var out: [PromptInput] = []
        for item in history {
            switch item {
            case .userMessage(_, let c):
                let t = c.compactMap { $0.text }.joined(separator: "\n")
                if !t.isEmpty { out.append(.userText(t)) }
            case .agentMessage(_, let t):
                if !t.isEmpty { out.append(.assistantText(t)) }
            case .commandExecution(let id, _, _, _, let o, _):
                if let o { out.append(.toolOutput(callId: id.raw, output: o)) }
            case .contextMessage(_, let role, let sections):
                for s in sections where !s.isEmpty {
                    switch role {
                    case "developer": out.append(.developerText(s))
                    case "assistant": out.append(.assistantText(s))
                    default: out.append(.userText(s))
                    }
                }
            case .reasoning, .fileChange, .contextCompaction, .unknown:
                // `.unknown` items are upstream ThreadItem variants Swift has
                // not modeled (mcpToolCall, webSearch, etc.). They are
                // captured for round-trip but contribute nothing to the
                // model prompt.
                continue
            }
        }
        out.append(contentsOf: extra)
        return out
    }

    public func snapshotText() -> String {
        history.map { item in
            switch item {
            case .userMessage(_, let c): return "user: " + c.compactMap { $0.text }.joined(separator: " ")
            case .agentMessage(_, let t): return "assistant: " + t
            case .reasoning(_, let s): return "reasoning: " + s
            case .commandExecution(_, let cmd, _, _, let o, _):
                return "tool \(cmd.joined(separator: " ")): " + (o ?? "")
            case .fileChange(_, let ch, _): return "filechange: " + ch.map(\.path).joined(separator: ",")
            case .contextMessage(_, let role, let sections):
                return "\(role): " + sections.joined(separator: "\n")
            case .contextCompaction:
                return "context_compaction"
            case .unknown(_, let typeName, _):
                return "unknown(\(typeName))"
            }
        }.joined(separator: "\n")
    }
}