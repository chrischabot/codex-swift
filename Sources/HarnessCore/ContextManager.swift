import Foundation
import InfraPrimitives
import ProtocolModel
import ModelClient

/// In-memory conversation transcript with Codex-faithful token accounting.
///
/// Mirrors `core/src/context_manager/history.rs`:
/// - per-item token estimate = ceil(model-visible bytes / 4) where
///   model-visible bytes is the JSON-serialized item length for ordinary
///   items, or `estimate_reasoning_length(encrypted_content.len())` for an
///   encrypted reasoning/compaction item
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

    /// Port of `estimate_reasoning_length`
    /// (`core/src/context_manager/history.rs:499-505`):
    /// `encoded_len * 3 / 4 - 650`, saturating at 0. The server already
    /// accounted for the encrypted reasoning tokens and the base64 blob is not
    /// re-ingested verbatim by the model, so the model-visible byte cost of an
    /// encrypted reasoning/compaction item is the decoded payload size minus a
    /// fixed offset, NOT the serialized JSON length.
    static func estimateReasoningLength(_ encodedLen: Int) -> Int {
        let scaled = max(0, encodedLen) * 3 / 4
        return max(0, scaled - 650)
    }

    /// `estimate_response_item_model_visible_bytes`
    /// (`core/src/context_manager/history.rs:534-545`): a Reasoning item with
    /// `encrypted_content: Some(_)` (and likewise Compaction / ContextCompaction
    /// carrying encrypted content) is costed as
    /// `estimate_reasoning_length(content.len())` model-visible bytes; every
    /// other item is its raw serialized JSON byte length. (Our `ThreadItem`
    /// model has no image-data-URL case, so no image discounting applies; and
    /// `.contextCompaction` carries no encrypted content in the Swift model.)
    static func modelVisibleBytes(of item: ThreadItem) -> Int {
        if case let .reasoning(_, _, _, encryptedContent) = item,
           let encrypted = encryptedContent {
            return estimateReasoningLength(encrypted.utf8.count)
        }
        return (try? JSONEncoder().encode(item))?.count ?? 0
    }
    static func estimateItemTokens(_ item: ThreadItem) -> Int {
        tokensFromBytes(modelVisibleBytes(of: item))
    }

    /// Codex `is_model_generated_item`
    /// (`core/src/context_manager/history.rs:681-699`).
    ///
    /// Upstream returns `true` for assistant messages, reasoning, the
    /// model-emitted CALL side of every tool (`FunctionCall`, `ToolSearchCall`,
    /// `WebSearchCall`, `ImageGenerationCall`, `CustomToolCall`,
    /// `LocalShellCall`), and for both compaction markers
    /// (`Compaction => true`, `ContextCompaction => true`). It returns `false`
    /// for user messages, the tool OUTPUT side (`FunctionCallOutput`, …),
    /// `CompactionTrigger`, and `Other`.
    ///
    /// `.contextCompaction` is treated as model-generated here so that after a
    /// remote compaction — whose installed history ends with a
    /// `.contextCompaction` marker (see SessionEngine appending
    /// `.contextCompaction`) — `itemsAfterLastModelGenerated()` returns an
    /// empty slice and `totalTokenUsage()` re-baselines to the last server
    /// total rather than re-counting the synthesized summary/user items on top
    /// of a stale `lastServerTotalTokens`.
    ///
    /// `.commandExecution` is an INTENTIONAL port divergence and stays in the
    /// `false` arm: the Swift `ThreadItem` model unifies a tool call and its
    /// output into a single `.commandExecution` variant (see Items.swift), so
    /// there is no separate call-side boundary item to mark `true`. Upstream's
    /// `FunctionCall => true` / `FunctionCallOutput => false` split has no
    /// 1:1 mapping here; collapsing both into one non-model-generated item
    /// counts the whole unified entry as "after the boundary", which is the
    /// closest faithful behaviour for the unified model. Do NOT "fix" this to
    /// return `true` — it is a deliberate consequence of the unified item
    /// model, not a bug.
    private static func isModelGenerated(_ item: ThreadItem) -> Bool {
        switch item {
        case .agentMessage, .reasoning, .contextCompaction: return true
        case .userMessage, .commandExecution, .fileChange, .collabAgentToolCall,
             .contextMessage, .enteredReviewMode, .exitedReviewMode, .unknown: return false
        }
    }
    /// Codex `is_codex_generated_item`
    /// (`core/src/context_manager/history.rs:701-708`): returns `true` ONLY for
    /// the tool-OUTPUT side of a tool call (`FunctionCallOutput`,
    /// `ToolSearchOutput`, `CustomToolCallOutput`) and for `developer`-role
    /// messages. This is the predicate the remote-compaction pre-request trim
    /// (`trim_function_call_history_to_fit_context_window`, compact_remote.rs:361-388)
    /// uses to decide which trailing items may be dropped so the compact request
    /// fits the model context window.
    ///
    /// INTENTIONAL PORT DIVERGENCE (matching `isModelGenerated`'s treatment of
    /// the unified item model): the Swift `ThreadItem` model unifies a tool call
    /// and its output into a single `.commandExecution` entry, so there is no
    /// standalone tool-OUTPUT item to mark `true`. `.commandExecution` therefore
    /// returns `false` here — it is NOT trimmable as a codex-generated item —
    /// preserving the same unified-item semantics as `isModelGenerated`. Do NOT
    /// "fix" this to return `true` for outputs; it is a deliberate consequence of
    /// the unified item model. The remaining codex-generated case the Swift model
    /// can express is a `developer`-role `.contextMessage`.
    static func isCodexGeneratedItem(_ item: ThreadItem) -> Bool {
        if case let .contextMessage(_, role, _) = item, role == "developer" {
            return true
        }
        return false
    }

    /// Port of `trim_function_call_history_to_fit_context_window`
    /// (`core/src/compact_remote.rs:361-388`): before issuing a remote compaction
    /// request, trim trailing codex-generated items (developer messages — see
    /// `isCodexGeneratedItem`) while the whole-history estimate exceeds the model
    /// context window, so the compact request itself fits. Stops as soon as the
    /// estimate fits, the last item is NOT codex-generated, or history is empty.
    ///
    /// `contextWindow == nil` mirrors upstream's `let Some(context_window) = …
    /// else { return 0 }`: with no declared window the trim is a no-op (limit
    /// effectively disabled). A safety counter (bounded by the initial history
    /// count) guards against an unproductive loop where an item's token cost is
    /// zero, so a broken estimate can never spin forever. Returns the number of
    /// items removed.
    @discardableResult
    public mutating func trimToFitContextWindow(contextWindow: Int?) -> Int {
        guard let contextWindow else { return 0 }
        var deleted = 0
        var attemptsRemaining = history.count
        while estimatedTokens > contextWindow {
            guard attemptsRemaining > 0 else { break }
            attemptsRemaining -= 1
            guard let last = history.last else { break }
            guard Self.isCodexGeneratedItem(last) else { break }
            guard removeLastItem() else { break }
            deleted += 1
        }
        return deleted
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
        case (.commandExecution(let id, let cmd, let cwd, let st, let actions, let out, let ec,
                                let pid, let source, let durationMs), .some(let cap)):
            let budget = Int(Double(cap) * 1.2)
            let truncated = out.map { Self.truncate($0, maxBytes: budget) }
            history.append(.commandExecution(id: id, command: cmd, cwd: cwd, status: st,
                                             commandActions: actions,
                                             aggregatedOutput: truncated, exitCode: ec,
                                             processId: pid, source: source,
                                             durationMs: durationMs))
        default:
            history.append(item)
        }
    }

    public mutating func appendUser(_ input: [TurnInput]) {
        let content = input.map { i -> UserMessageContent in
            var c = UserMessageContent(text: i.text ?? "")
            c.type = i.type; c.url = i.url; c.path = i.path
            // Thread image detail + text-span metadata through to history so
            // they round-trip and reach the model input builder instead of
            // being silently dropped (upstream `UserInput` → `CoreUserInput`).
            c.detail = i.detail; c.textElements = i.textElements
            return c
        }
        history.append(.userMessage(id: ItemId.generate("u"), content: content))
    }

    public mutating func appendAssistant(_ text: String, id: ItemId) {
        history.append(.agentMessage(id: id, text: text))
    }

    /// Records a reasoning item (encrypted chain-of-thought + flattened
    /// summary/content) so it is replayed into the next request's input and
    /// persisted in the rollout — parity with upstream feeding
    /// `ResponseItem::Reasoning` back via `get_formatted_input`.
    public mutating func appendReasoning(id: ItemId, summary: [String],
                                         content: [String],
                                         encryptedContent: String?) {
        history.append(.reasoning(id: id, summary: summary, content: content,
                                  encryptedContent: encryptedContent))
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
    /// True iff `s` is a non-empty OpenAI function identifier (`^[A-Za-z0-9_-]+$`).
    /// Used to keep a replayed `function_call` name valid on the wire.
    static func isValidFunctionName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for u in s.unicodeScalars {
            let v = u.value
            let ok = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                || (0x30...0x39).contains(v) || v == 0x5F || v == 0x2D
            if !ok { return false }
        }
        return true
    }

    public func forPrompt(extra: [PromptInput] = []) -> [PromptInput] {
        var out: [PromptInput] = []
        for item in history {
            switch item {
            case .userMessage(_, let c):
                let t = c.compactMap { $0.text }.joined(separator: "\n")
                if !t.isEmpty { out.append(.userText(t)) }
            case .agentMessage(_, let t):
                if !t.isEmpty { out.append(.assistantText(t)) }
            case .commandExecution(let id, let command, _, _, _, let o, _, _, let source, _):
                // Replay the REAL tool name on the synthesized function_call so
                // the model sees WHICH call produced this output across
                // iterations (mirrors codex-rs replaying the verbatim
                // `ResponseItem::FunctionCall` name; previously every call was a
                // generic "tool"). The name lives on the structured
                // `function_call` item, NOT prefixed into the output text — so
                // the output text stays clean (parity with upstream's separate
                // FunctionCall / FunctionCallOutput items). The Swift unified
                // `.commandExecution` item does not retain the original
                // arguments string (see Rollout.swift:843-880), so `"{}"` is
                // passed for `argumentsJSON`.
                if let o {
                    // The name MUST be a valid OpenAI function identifier
                    // (^[A-Za-z0-9_-]+$) or the Responses API rejects the whole
                    // request with 400. For an agent tool-call `command.first` IS
                    // the tool name (valid). For a `.userShell` execution
                    // `command` holds the raw user-typed command (e.g.
                    // "git status"), which is NOT a valid name — that ran via the
                    // shell tool, so use "shell_command". The `isValidFunctionName`
                    // guard also catches any other non-conforming name defensively.
                    let raw = command.first ?? "tool"
                    let name = (source == .userShell || !Self.isValidFunctionName(raw))
                        ? "shell_command" : raw
                    out.append(.toolOutput(callId: id.raw, name: name,
                                           argumentsJSON: "{}", output: o))
                }
            case .contextMessage(_, let role, let sections):
                for s in sections where !s.isEmpty {
                    switch role {
                    case "developer": out.append(.developerText(s))
                    case "assistant": out.append(.assistantText(s))
                    default: out.append(.userText(s))
                    }
                }
            case .reasoning(_, let summary, let content, let encryptedContent):
                // Replay reasoning items into the model input so encrypted
                // chain-of-thought survives across turns (Codex
                // `attach_item_ids` / `get_formatted_input` feeds Reasoning
                // items back; client.rs requests `reasoning.encrypted_content`).
                // Only replay items that carry encrypted content OR some
                // summary/content text — an empty reasoning item contributes
                // nothing and is skipped to keep the input array clean.
                if encryptedContent != nil || !summary.isEmpty || !content.isEmpty {
                    out.append(.reasoning(summary: summary, content: content,
                                          encryptedContent: encryptedContent))
                }
            case .fileChange(let id, let changes, _):
                // FAITHFUL CONTEXT FIX: codex-rs replays the agent's apply_patch
                // edits into the next prompt so it remembers what it changed;
                // codex-swift had been SKIPPING .fileChange entirely, so on every
                // follow-up iteration the model could not see it had edited any
                // file via its primary editing tool — the dominant cause of
                // "re-discovers and only implements 30-50% of the spec". Emit the
                // applied patch (path + kind + diff) as the apply_patch output so
                // the edit stays visible across iterations.
                if !changes.isEmpty {
                    let rendered = changes.map { ch -> String in
                        let verb: String
                        switch ch.kind {
                        case .add: verb = "added"
                        case .delete: verb = "deleted"
                        case .update: verb = "updated"
                        }
                        return "[apply_patch] \(verb) \(ch.path)\n\(ch.diff)"
                    }.joined(separator: "\n")
                    // The apply_patch edits are replayed as the `apply_patch`
                    // tool's function_call_output so the model remembers what it
                    // changed. The real tool name is `apply_patch`; the unified
                    // `.fileChange` item does not retain the original arguments
                    // string, so `"{}"` is passed for `argumentsJSON`.
                    out.append(.toolOutput(callId: id.raw, name: "apply_patch",
                                           argumentsJSON: "{}", output: rendered))
                }
            case .collabAgentToolCall, .contextCompaction,
                 .enteredReviewMode, .exitedReviewMode, .unknown:
                // `.unknown` items are upstream ThreadItem variants Swift has
                // not modeled (mcpToolCall, webSearch, etc.). They are
                // captured for round-trip but contribute nothing to the
                // model prompt. `collabAgentToolCall` is a wire-surface item
                // with no model-input projection. `enteredReviewMode` /
                // `exitedReviewMode` are frontend thread-history markers only —
                // the review-exit guidance is replayed via a separate
                // agentMessage, so these contribute nothing to the model input.
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
            case .reasoning(_, let s, _, _): return "reasoning: " + s.joined(separator: "\n")
            case .commandExecution(_, let cmd, _, _, _, let o, _, _, _, _):
                return "tool \(cmd.joined(separator: " ")): " + (o ?? "")
            case .fileChange(_, let ch, _): return "filechange: " + ch.map(\.path).joined(separator: ",")
            case .contextMessage(_, let role, let sections):
                return "\(role): " + sections.joined(separator: "\n")
            case .collabAgentToolCall(_, let tool, _, _, _, _, _, _, _):
                return "collabAgentToolCall: \(tool.rawValue)"
            case .contextCompaction:
                return "context_compaction"
            case .enteredReviewMode(_, let review):
                return "entered_review_mode: " + review
            case .exitedReviewMode(_, let review):
                return "exited_review_mode: " + review
            case .unknown(_, let typeName, _):
                return "unknown(\(typeName))"
            }
        }.joined(separator: "\n")
    }
}