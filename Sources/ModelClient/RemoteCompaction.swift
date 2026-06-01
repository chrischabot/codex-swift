import Foundation

/// Wire types + request building for the remote `/responses/compact` endpoint
/// (the server-side summarization the default OpenAI provider uses instead of
/// the local prompt-driven compaction).
///
/// Faithful port of:
///   - `codex-rs/codex-api/src/endpoint/compact.rs` (path `responses/compact`,
///     `CompactClient::compact`, `CompactHistoryResponse { output }`)
///   - `codex-rs/codex-api/src/common.rs:24-40` (`CompactionInput` payload)
///   - `codex-rs/core/src/client.rs:433-515`
///     (`compact_conversation_history` — derives the payload from the same
///     `build_responses_request` the streaming turn uses, then POSTs it)
///
/// IMPORTANT — wire shape: the upstream `CompactionInput` struct carries NO
/// `#[serde(rename_all)]`, so serde serializes it with snake_case field names
/// (`parallel_tool_calls`, `service_tier`, `prompt_cache_key`), exactly like
/// `ResponsesApiRequest`. We reproduce that here. Optional fields use serde
/// `skip_serializing_if`: `instructions` is omitted when empty; `reasoning`,
/// `service_tier`, `prompt_cache_key`, `text` are omitted when nil.
public enum RemoteCompaction {
    /// One item parsed out of the compact endpoint's `output` array.
    /// Upstream returns `Vec<ResponseItem>`; the variants that survive
    /// `should_keep_compacted_history_item` (`compact_remote.rs:293-318`) and
    /// matter to the Swift port's transcript are:
    ///   - role-bearing `message` items (`.message`), and
    ///   - `Compaction` / `ContextCompaction` output items
    ///     (`.compaction` / `.contextCompaction`), which carry an encrypted
    ///     payload (`encrypted_content`) and are explicitly RETAINED by
    ///     upstream (`ResponseItem::Compaction | ContextCompaction => true`).
    /// We surface all three so the retention rule can be applied faithfully at
    /// the call site (`SessionEngine.tryRemoteCompaction`).
    public struct OutputMessage: Sendable, Equatable {
        /// Which `ResponseItem` family this output item came from.
        public enum Kind: Sendable, Equatable {
            /// A role-bearing `ResponseItem::Message`.
            case message
            /// `ResponseItem::Compaction { encrypted_content }`.
            case compaction
            /// `ResponseItem::ContextCompaction { encrypted_content }`.
            case contextCompaction
        }
        public var kind: Kind
        /// Message role ("user"/"assistant"/"developer"/"system"). For
        /// compaction items this is empty (they carry no role).
        public var role: String
        /// Message text. For compaction items this is empty.
        public var text: String
        /// The opaque `encrypted_content` carried by a `Compaction` /
        /// `ContextCompaction` item (nil for plain messages). Preserved so the
        /// retained item survives `process_compacted_history` intact.
        public var encryptedContent: String?

        public init(role: String, text: String) {
            self.kind = .message
            self.role = role
            self.text = text
            self.encryptedContent = nil
        }

        public init(kind: Kind, role: String = "", text: String = "",
                    encryptedContent: String? = nil) {
            self.kind = kind
            self.role = role
            self.text = text
            self.encryptedContent = encryptedContent
        }
    }

    /// Builds the `/responses/compact` request body from a `Prompt` +
    /// `ModelSettings`, mirroring `compact_conversation_history`'s extraction of
    /// the `CompactionInput` fields out of `build_responses_request`'s
    /// `ResponsesApiRequest`. Snake_case + `skip_serializing_if` parity:
    ///   - `instructions` omitted when empty (`str::is_empty`)
    ///   - `reasoning` omitted when nil (NOT emitted as `null`, unlike the
    ///     streaming body — `CompactionInput.reasoning` is
    ///     `skip_serializing_if = Option::is_none`)
    ///   - `service_tier`, `prompt_cache_key`, `text` omitted when nil/empty
    ///   - `tools` + `parallel_tool_calls` always present
    public static func buildRequestBody(_ prompt: Prompt,
                                        _ settings: ModelSettings) -> [String: Any] {
        var input: [[String: Any]] = []
        for item in prompt.input {
            switch item {
            case .userText(let t):
                input.append(["role": "user",
                              "content": [["type": "input_text", "text": t]]])
            case .developerText(let t):
                input.append(["role": "developer",
                              "content": [["type": "input_text", "text": t]]])
            case .assistantText(let t):
                input.append(["role": "assistant",
                              "content": [["type": "output_text", "text": t]]])
            case .toolOutput(let callId, let name, let argumentsJSON, let output):
                // Replay the originating function_call with the REAL tool name
                // + arguments (parity with the streaming request body; upstream
                // replays the verbatim `ResponseItem::FunctionCall`).
                input.append(["type": "function_call", "call_id": callId,
                              "name": name, "arguments": argumentsJSON])
                input.append(["type": "function_call_output",
                              "call_id": callId, "output": output])
            case .reasoning(let summary, let content, let encryptedContent):
                // Carry reasoning items into the compaction input as well so
                // the server has the same transcript shape (parity with the
                // streaming request body).
                var item: [String: Any] = [
                    "type": "reasoning",
                    "summary": summary.map {
                        ["type": "summary_text", "text": $0]
                    },
                    "encrypted_content": encryptedContent.map { $0 as Any }
                        ?? NSNull(),
                ]
                if !content.isEmpty {
                    item["content"] = content.map {
                        ["type": "reasoning_text", "text": $0]
                    }
                }
                input.append(item)
            }
        }

        var body: [String: Any] = [
            "model": settings.model,
            "input": input,
            "parallel_tool_calls": settings.parallelToolCalls,
        ]

        // `instructions`: skip when empty (`str::is_empty`).
        if !prompt.instructions.isEmpty {
            body["instructions"] = prompt.instructions
        }

        // `tools`: always serialized (`Vec<Value>`); empty array when none.
        if prompt.tools.isEmpty {
            body["tools"] = [] as [Any]
        } else {
            body["tools"] = prompt.tools.map { spec -> [String: Any] in
                if let fmt = spec.freeformFormat {
                    return ["type": "custom", "name": spec.name,
                            "description": spec.description,
                            "format": ["type": fmt.type, "syntax": fmt.syntax,
                                       "definition": fmt.definition]]
                }
                let params = ((try? JSONSerialization.jsonObject(
                    with: Data(spec.parametersJSON.utf8))) as? [String: Any])
                    ?? ["type": "object", "additionalProperties": true]
                // Always emit `strict`; never emit `output_schema`
                // (upstream `ResponsesApiTool`: `strict` non-skippable,
                // `output_schema` is `#[serde(skip)]`).
                let entry: [String: Any] = ["type": "function", "name": spec.name,
                                            "description": spec.description,
                                            "strict": spec.strict,
                                            "parameters": params]
                return entry
            }
        }

        // `reasoning`: resolved via the same `build_reasoning` gating as the
        // streaming builder (catalog-aware, tri-state). Unlike the streaming
        // body, `CompactionInput.reasoning` is
        // `skip_serializing_if = Option::is_none`, so when no reasoning object
        // is produced the key is OMITTED entirely (not emitted as `null`).
        if let reasoning = ReasoningResolution.resolveReasoning(settings) {
            body["reasoning"] = reasoning
        }

        // `service_tier`: skip when nil/empty, and gate on model-catalog
        // support like upstream (`client.rs:744-745`) — drop a tier the
        // resolved model does not advertise (`supportsServiceTier == false`).
        if let tier = settings.serviceTier, !tier.isEmpty,
           settings.supportsServiceTier != false {
            body["service_tier"] = tier
        }

        // `prompt_cache_key`: skip when empty. (Upstream's
        // `build_responses_request` sets this to the thread id.)
        if !settings.threadId.isEmpty {
            body["prompt_cache_key"] = settings.threadId
        }

        // `text`: verbosity controls, gated on model support; skip when none.
        if let verbosity = ReasoningResolution.resolveVerbosity(settings) {
            body["text"] = ["verbosity": verbosity]
        }

        return body
    }

    /// Parses the `{ "output": [ResponseItem] }` body returned by the compact
    /// endpoint into the role-bearing message items. Non-message items
    /// (reasoning, tool calls, …) are dropped here — they are filtered out by
    /// `should_keep_compacted_history_item` upstream anyway. Throws
    /// `ModelError` when the payload is not the expected shape.
    public static func parseOutput(_ data: Data) throws -> [OutputMessage] {
        guard let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
            throw ModelError("compact endpoint returned non-JSON body",
                             retryable: false)
        }
        if let err = root["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "compact endpoint error"
            throw ModelError(msg, retryable: false)
        }
        guard let output = root["output"] as? [[String: Any]] else {
            throw ModelError("compact endpoint response missing `output` array",
                             retryable: false)
        }
        var messages: [OutputMessage] = []
        for item in output {
            let type = item["type"] as? String
            switch type {
            // `ResponseItem::Compaction { encrypted_content: String }`
            // (`type: "compaction"`, serde alias `"compaction_summary"`). These
            // are explicitly retained by `should_keep_compacted_history_item`,
            // so surface them rather than dropping them. `encrypted_content` is
            // non-optional upstream.
            case "compaction", "compaction_summary":
                let enc = item["encrypted_content"] as? String
                messages.append(OutputMessage(kind: .compaction,
                                              encryptedContent: enc))
            // `ResponseItem::ContextCompaction { encrypted_content: Option<String> }`
            // (`type: "context_compaction"`). Also retained upstream;
            // `encrypted_content` may be absent.
            case "context_compaction":
                let enc = item["encrypted_content"] as? String
                messages.append(OutputMessage(kind: .contextCompaction,
                                              encryptedContent: enc))
            // Role-bearing `ResponseItem::Message` items (an explicit `message`
            // type, or a bare `{role, content}` object with no `type`).
            case .some("message"), .none:
                guard let role = item["role"] as? String else { continue }
                var text = ""
                if let content = item["content"] as? [[String: Any]] {
                    for c in content {
                        if let s = c["text"] as? String { text += s }
                    }
                } else if let s = item["text"] as? String {
                    text = s
                }
                messages.append(OutputMessage(role: role, text: text))
            // Everything else (reasoning, tool calls, …) is dropped — it is
            // filtered out by `should_keep_compacted_history_item` anyway.
            default:
                continue
            }
        }
        return messages
    }

    /// `(START_MARKER, END_MARKER)` pairs for the contextual fragments
    /// registered in `CONTEXTUAL_USER_FRAGMENTS`
    /// (`context/contextual_user_message.rs:42-53`) whose markers are non-empty
    /// (so `matches_text` can actually fire). Note: `is_standard_contextual_user_text`
    /// matches purely by text against the REGISTERED fragment list and does NOT
    /// look at each fragment's `ROLE`, so a `user`-role message whose text hits
    /// any registered marker is dropped. The registered non-empty-marker
    /// fragments are: UserInstructions, EnvironmentContext, SkillInstructions,
    /// UserShellCommand, TurnAborted, SubagentNotification, GoalContext. The
    /// three legacy warnings in the list have empty markers (`matches_text`
    /// short-circuits to `false`); developer-role fragments NOT in the
    /// registered list (CollaborationModeInstructions, PermissionsInstructions,
    /// ModelSwitchInstructions, AppsInstructions, PersonalitySpecInstructions,
    /// realtime fragments) are correctly excluded. Markers are sourced from each
    /// fragment's `START_MARKER`/`END_MARKER` consts.
    private static let contextualUserMarkers: [(open: String, close: String)] = [
        // UserInstructions (user_instructions.rs:11-12)
        ("# AGENTS.md instructions for ", "</INSTRUCTIONS>"),
        // EnvironmentContext (environment_context.rs:273-274)
        ("<environment_context>", "</environment_context>"),
        // SkillInstructions (skill_instructions.rs:24-25) — ROLE=user, in the
        // registered `CONTEXTUAL_USER_FRAGMENTS` list.
        ("<skill>", "</skill>"),
        // UserShellCommand (user_shell_command.rs:31-32)
        ("<user_shell_command>", "</user_shell_command>"),
        // TurnAborted (turn_aborted.rs:21-22)
        ("<turn_aborted>", "</turn_aborted>"),
        // SubagentNotification (subagent_notification.rs:22-23)
        ("<subagent_notification>", "</subagent_notification>"),
        // GoalContext (goal_context.rs:12-13)
        ("<goal_context>", "</goal_context>"),
    ]

    /// Mirrors `ContextualUserFragment::matches_text` (`context/fragment.rs:47-64`):
    /// case-insensitive START_MARKER prefix + END_MARKER suffix on the
    /// `trim_start()`/`trim_end()`-trimmed text. Returns false for empty markers.
    private static func matchesMarker(_ text: String, open: String, close: String)
    -> Bool {
        if open.isEmpty || close.isEmpty { return false }
        let leading = text.drop { $0 == " " || $0 == "\t" || $0 == "\n"
            || $0 == "\r" || $0.isWhitespace }
        guard leading.count >= open.count else { return false }
        let startsWith = leading.prefix(open.count).lowercased() == open.lowercased()
        // trim_end for the suffix check.
        var trimmedEnd = Substring(leading)
        while let last = trimmedEnd.last, last.isWhitespace {
            trimmedEnd = trimmedEnd.dropLast()
        }
        guard trimmedEnd.count >= close.count else { return false }
        let endsWith = trimmedEnd.suffix(close.count).lowercased() == close.lowercased()
        return startsWith && endsWith
    }

    /// True when a `user`-role remote-compaction message text looks like a
    /// hook-prompt fragment (`<hook_prompt hook_run_id="…">…</hook_prompt>`).
    /// Hook-prompt messages parse as `TurnItem::HookPrompt` upstream and are
    /// therefore RETAINED (`parse_turn_item` → `HookPrompt`), unlike the other
    /// contextual wrappers. Faithful (text-level) check for
    /// `parse_hook_prompt_fragment` (`protocol/src/items.rs:409-417`): the tag
    /// must be present and carry a non-empty `hook_run_id`.
    private static func looksLikeHookPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("<hook_prompt"),
              t.lowercased().hasSuffix("</hook_prompt>") else { return false }
        // Require a non-empty `hook_run_id="…"` attribute (upstream rejects an
        // empty/whitespace id).
        guard let r = t.range(of: "hook_run_id", options: .caseInsensitive) else {
            return false
        }
        let after = t[r.upperBound...]
        guard let q1 = after.firstIndex(of: "\"") else { return false }
        let rest = after[after.index(after: q1)...]
        guard let q2 = rest.firstIndex(of: "\"") else { return false }
        let id = rest[rest.startIndex..<q2].trimmingCharacters(in: .whitespaces)
        return !id.isEmpty
    }

    /// `should_keep_compacted_history_item` for a `user`-role message
    /// (`compact_remote.rs:296-301` → `parse_turn_item` →
    /// `HookPrompt | UserMessage`): keep the message unless it is a contextual
    /// session-prefix/instruction wrapper that does NOT parse as a hook prompt.
    /// - Hook-prompt messages are kept (parse as `TurnItem::HookPrompt`).
    /// - Messages whose text matches a standard contextual user fragment marker
    ///   are dropped (they parse as neither `HookPrompt` nor `UserMessage`).
    /// - All other (real) user messages are kept.
    public static func shouldKeepUserMessage(_ text: String) -> Bool {
        if looksLikeHookPrompt(text) { return true }
        for m in contextualUserMarkers where matchesMarker(text, open: m.open,
                                                           close: m.close) {
            return false
        }
        return true
    }

    /// `/responses/compact` URL derived from a provider's responses URL by
    /// swapping the `/responses` suffix for `/responses/compact` (preserving
    /// any query params). Mirrors `RESPONSES_COMPACT_ENDPOINT`.
    public static func compactURL(fromResponsesURL responsesURL: String) -> String {
        // Split off query string so we insert `/compact` before it.
        let parts = responsesURL.split(separator: "?", maxSplits: 1,
                                       omittingEmptySubsequences: false)
        var path = String(parts[0])
        if path.hasSuffix("/responses") {
            path += "/compact"
        } else if let range = path.range(of: "/responses",
                                         options: .backwards) {
            path.replaceSubrange(range, with: "/responses/compact")
        } else {
            path += "/compact"
        }
        if parts.count == 2 {
            return path + "?" + String(parts[1])
        }
        return path
    }
}

public extension ModelClient {
    /// Default: the provider does not support the remote compact endpoint, so
    /// the engine falls back to local prompt-driven compaction. Mirrors
    /// `supports_remote_compaction()` defaulting to false for providers that
    /// are not OpenAI / Azure-Responses.
    func compactConversationHistory(_ prompt: Prompt,
                                    _ settings: ModelSettings) async throws
    -> [RemoteCompaction.OutputMessage]? {
        nil
    }
}
