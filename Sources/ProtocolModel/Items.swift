import Foundation
import WireProtocol

public enum ItemStatus: String, Sendable, Codable {
    case inProgress, completed, failed, declined
}

/// Upstream `CommandExecutionSource` (app-server-protocol/v2/item.rs:895-903),
/// derived from core `ExecCommandSource`. `#[serde(default)]` with default
/// `Agent`, so the field is always serialized. camelCase wire values.
public enum CommandExecutionSource: String, Sendable, Codable, Equatable {
    case agent
    case userShell
    case unifiedExecStartup
    case unifiedExecInteraction
}

/// Upstream `MessagePhase` (codex-protocol/src/models.rs:740-748, referenced by
/// v2 `ThreadItem::AgentMessage.phase`). `#[serde(rename_all = "snake_case")]`
/// → `commentary` / `final_answer` on the wire.
public enum MessagePhase: String, Sendable, Codable, Equatable {
    case commentary
    case finalAnswer = "final_answer"
}

/// Upstream `MemoryCitation` (app-server-protocol/v2/item.rs:125-132):
/// `{ entries: Vec<MemoryCitationEntry>, threadIds: Vec<String> }`. Both fields
/// are required, camelCase per `#[serde(rename_all = "camelCase")]`.
public struct MemoryCitation: Sendable, Codable, Equatable {
    /// Upstream `MemoryCitationEntry` (v2/item.rs:143-149):
    /// `{ path, lineStart, lineEnd, note }`, all required, camelCase.
    public struct Entry: Sendable, Codable, Equatable {
        public var path: String
        public var lineStart: Int
        public var lineEnd: Int
        public var note: String
        public init(path: String, lineStart: Int, lineEnd: Int, note: String) {
            self.path = path; self.lineStart = lineStart
            self.lineEnd = lineEnd; self.note = note
        }
    }
    public var entries: [Entry]
    public var threadIds: [String]
    public init(entries: [Entry], threadIds: [String]) {
        self.entries = entries; self.threadIds = threadIds
    }
}

/// Upstream `ByteRange` (app-server-protocol/v2/turn.rs:176-179):
/// `{ start: usize, end: usize }`, camelCase, both fields required.
public struct ByteRange: Sendable, Codable, Equatable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

/// Upstream `TextElement` (app-server-protocol/v2/turn.rs:198-208):
/// `{ byteRange: ByteRange, placeholder: Option<String> }`, camelCase.
/// `placeholder` has NO `skip_serializing_if`, so serde always emits it
/// (`null` when absent); only `byteRange` is `required` in the schema.
public struct TextElement: Sendable, Codable, Equatable {
    public var byteRange: ByteRange
    public var placeholder: String?
    public init(byteRange: ByteRange, placeholder: String? = nil) {
        self.byteRange = byteRange; self.placeholder = placeholder
    }
    private enum CodingKeys: String, CodingKey { case byteRange, placeholder }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(byteRange, forKey: .byteRange)
        // No `skip_serializing_if` upstream → always emit (`null` when nil).
        try c.encode(placeholder, forKey: .placeholder)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.byteRange = try c.decode(ByteRange.self, forKey: .byteRange)
        self.placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
    }
}

/// Upstream `ImageDetail` (codex-protocol/src/models.rs:725-730), referenced by
/// the v2 `UserInput::Image` / `UserInput::LocalImage` `detail` field.
/// `#[serde(rename_all = "lowercase")]` → wire values `high` / `original`.
public enum ImageDetail: String, Sendable, Codable, Equatable {
    case high
    case original
}

/// Mirror of the v2 `UserInput` enum (app-server-protocol/v2/turn.rs:241-272),
/// the internally-tagged (`tag = "type"`) payload of a `userMessage`
/// `ThreadItem`. Modeled as a single struct keyed by `type`
/// ("text" | "image" | "localImage").
///
/// The `Text` variant carries `text_elements: Vec<TextElement>` with
/// `#[serde(default)]` and NO `skip_serializing_if`, so serde ALWAYS emits
/// `"text_elements": []` on a text input (snake_case: serde's enum-level
/// `rename_all` renames variant NAMES only, not struct-variant fields). The
/// image/localImage variants do NOT carry the field, so the custom encoder
/// emits `text_elements` ONLY when `type == "text"`, matching upstream
/// byte-for-byte.
public struct UserMessageContent: Sendable, Codable, Equatable {
    public var type: String   // "text" | "image" | "localImage"
    public var text: String?
    public var url: String?
    public var path: String?
    /// UI-defined spans within `text`; always serialized on the `text`
    /// variant (empty array when unset), absent on image variants.
    public var textElements: [TextElement]
    /// Image fidelity for the `image` / `localImage` variants
    /// (upstream `UserInput::Image/LocalImage { detail: Option<ImageDetail> }`,
    /// `#[serde(default)]` + `#[ts(optional)]`). Optional/omitted on the wire
    /// when absent; never present on the `text` variant.
    public var detail: ImageDetail?
    public init(text: String) {
        self.type = "text"; self.text = text; self.textElements = []
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, url, path, detail
        // Upstream `UserInput::Text { text_elements }` is a struct-variant field;
        // serde's enum-level `rename_all = "camelCase"` renames variant NAMES
        // only, NOT struct-variant fields, so the wire key stays snake_case
        // `text_elements` (generated TS binding: `text_elements: Array<TextElement>`).
        case textElements = "text_elements"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(path, forKey: .path)
        // Upstream only the `Text` variant carries `text_elements` (always
        // emitted, never skipped). Image / localImage variants omit it.
        if type == "text" {
            try c.encode(textElements, forKey: .textElements)
        } else {
            // `detail` lives only on the image / localImage variants. It is
            // `#[serde(default)]` + `#[ts(optional)]` upstream, so it is
            // omitted from the wire when absent.
            try c.encodeIfPresent(detail, forKey: .detail)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(String.self, forKey: .type)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        // Tolerate a missing key (legacy / non-text variants) → default [].
        self.textElements = (try? c.decodeIfPresent([TextElement].self, forKey: .textElements)) ?? [] ?? []
        self.detail = try? c.decodeIfPresent(ImageDetail.self, forKey: .detail) ?? nil
    }
}

public enum ThreadItem: Sendable, Equatable {
    case userMessage(id: ItemId, content: [UserMessageContent])
    /// Upstream `ThreadItem::AgentMessage` (app-server-protocol/v2/item.rs:223-231):
    /// `{ id, text, phase, memoryCitation }`. `phase` and `memoryCitation` carry
    /// `#[serde(default)]` but NO `skip_serializing_if`, so upstream ALWAYS
    /// serializes them (as `null` when absent).
    ///
    /// PORT NOTE: every emitter in this port constructs an agent message with no
    /// phase / memory citation, so the modeled surface stays `(id, text)` to
    /// avoid breaking the ~50 `case .agentMessage(_, let t)` pattern-match sites
    /// across the codebase. To stay byte-identical with upstream the encoder
    /// nonetheless emits `"phase": null` and `"memoryCitation": null` on every
    /// agentMessage (see `encode(to:)`), and the decoder tolerantly accepts (and
    /// ignores) any non-null values. The `MessagePhase` / `MemoryCitation` types
    /// below are the faithful models of the upstream payloads for any future
    /// emitter that needs to surface them.
    case agentMessage(id: ItemId, text: String)
    /// Upstream `ThreadItem::Reasoning { summary: Vec<String>, content:
    /// Vec<String> }` (app-server-protocol/v2/item.rs:240-245). Both fields are
    /// arrays on the wire; a frontend decodes `summary`/`content` as
    /// `string[]`. We keep both as `[String]` so the JSON shape matches.
    ///
    /// `encryptedContent` carries the opaque `encrypted_content` token the
    /// Responses API returns when `include == ["reasoning.encrypted_content"]`
    /// (Codex `ResponseItem::Reasoning.encrypted_content`,
    /// protocol/src/models.rs:774). It is NOT part of the v2 frontend
    /// `ThreadItem` wire shape (the v2 Codable omits it), but it IS persisted in
    /// the rollout (which uses the model `ResponseItem` shape) and replayed into
    /// the next request's input so encrypted chain-of-thought survives across
    /// turns. `nil` for reasoning items that predate this field.
    case reasoning(id: ItemId, summary: [String], content: [String],
                   encryptedContent: String? = nil)
    /// Upstream `ThreadItem::CommandExecution` (app-server-protocol/v2/item.rs:248-269).
    /// `commandActions` is the best-effort parse of the command into one or more
    /// `CommandAction`s; it is a required `Vec<CommandAction>` upstream (present
    /// even when empty), so it is emitted on the wire as an array on every
    /// `item/started` / `item/completed` notification.
    /// `processId` is the underlying PTY process id (when available);
    /// `source` defaults to `.agent` (always serialized upstream);
    /// `durationMs` is the execution duration in ms (`number | null` upstream).
    case commandExecution(id: ItemId, command: [String], cwd: String, status: ItemStatus,
                           commandActions: [CommandAction],
                           aggregatedOutput: String?, exitCode: Int?,
                           processId: String? = nil,
                           source: CommandExecutionSource = .agent,
                           durationMs: Int? = nil)
    case fileChange(id: ItemId, changes: [FileChange], status: ItemStatus)
    /// Upstream `ThreadItem::CollabAgentToolCall` (app-server-protocol/v2/item.rs:309-331).
    /// Surfaces a multi-agent collaboration tool call (spawn/sendInput/resume/
    /// wait/closeAgent) so a frontend can render multi-agent spawn/wait state.
    /// `prompt`/`model`/`reasoningEffort` are optional (`number | null`-style);
    /// `agentsStates` is the last-known per-thread agent status map.
    case collabAgentToolCall(id: ItemId, tool: CollabAgentTool,
                             status: CollabAgentToolCallStatus,
                             senderThreadId: String,
                             receiverThreadIds: [String],
                             prompt: String?,
                             model: String?,
                             reasoningEffort: ReasoningEffort?,
                             agentsStates: [String: CollabAgentState])
    /// DELIBERATE PORT EXTENSION — NOT an upstream v2 `ThreadItem` variant.
    ///
    /// Upstream's v2 `ThreadItem` union (app-server-protocol/v2/item.rs:209-362)
    /// has NO `contextMessage`; upstream surfaces initial/developer context and
    /// settings-diff updates INSIDE the model history via the core
    /// `ContextManager`, not as a wire ThreadItem. This port models that same
    /// history-only context as a typed `.contextMessage` so it can be appended
    /// to the in-memory context (`ContextManager`) and persisted to the rollout
    /// (model `ResponseItem` shape) for cross-turn replay.
    ///
    /// CONTRACT: this item is INTERNAL — it is appended to context and written
    /// to the rollout, but it is intentionally NEVER emitted on the v2
    /// `item/started` / `item/completed` notification streams a stock upstream
    /// frontend consumes (every emitter routes it through
    /// `ctx.appendItem` + `persist(.item(...))`, never `emit(.itemStarted/…)`).
    /// A frontend generated from upstream's TS `ThreadItem` types therefore
    /// never sees this discriminator on the live event surface; it appears only
    /// inside the rollout / model history, mirroring upstream's behaviour.
    ///
    /// A role ("developer" or "user") plus the ordered fragment section texts
    /// (each a separate `ContentItem::InputText` in Codex `build_*_update_item`).
    case contextMessage(id: ItemId, role: String, sections: [String])
    /// Codex `TurnItem::ContextCompaction(ContextCompactionItem)`: a marker
    /// item that brackets a context-compaction event in `itemStarted` /
    /// `itemCompleted` notifications. Distinct from an ordinary
    /// `.agentMessage` so UIs can render compaction as a structured event
    /// rather than an assistant turn whose text happens to be
    /// "<context_compaction>". Upstream carries only `id`.
    case contextCompaction(id: ItemId)
    /// Upstream `ThreadItem::EnteredReviewMode { id: String, review: String }`
    /// (app-server-protocol/v2/item.rs:355-356), serde `#[serde(tag = "type",
    /// rename_all = "camelCase")]` → wire `type:"enteredReviewMode"` with a
    /// required `review` string. `thread_history.rs:851-860` builds the
    /// `review` from `ReviewRequest.user_facing_hint`, falling back to
    /// "Review requested." A frontend switches into review UI on this item and
    /// surfaces the hint.
    case enteredReviewMode(id: ItemId, review: String)
    /// Upstream `ThreadItem::ExitedReviewMode { id: String, review: String }`
    /// (app-server-protocol/v2/item.rs:357-358). `thread_history.rs:862-875`
    /// builds the `review` from `render_review_output_text(review_output)`,
    /// falling back to `REVIEW_FALLBACK_MESSAGE`. Marks the end of review mode
    /// and carries the rendered review summary.
    case exitedReviewMode(id: ItemId, review: String)
    /// Tolerant fallback for upstream `ThreadItem` variants this Swift port
    /// has not yet modeled (e.g. `mcpToolCall`, `webSearch`, `hookPrompt`,
    /// `dynamicToolCall`, `imageView`, `imageGeneration`, `plan`,
    /// or any future `backgroundTerminal`-style additions). Decoding a
    /// `ThreadItem` whose `type` discriminator is unknown stores the entire
    /// JSON object verbatim in `raw` and the discriminator in `typeName`.
    /// Encoding writes the captured object back unchanged, preserving any
    /// fields the Swift surface does not yet know about.
    ///
    /// This prevents `item/started` / `item/completed` notifications from
    /// crashing the pipeline when upstream emits a tool-call item Swift
    /// cannot otherwise model. Subscribers may opt into rendering by
    /// inspecting `raw`; everyone else simply ignores the event.
    case unknown(id: ItemId, typeName: String, raw: JSONValue)

    /// Upstream `FileUpdateChange` (app-server-protocol/v2/item.rs:921):
    /// `{ path, kind: PatchChangeKind, diff }` where `kind` is the
    /// internally-tagged `{type: "add"|"delete"|"update", movePath?}` object —
    /// NOT a bare string, and the modify variant is named `update`.
    public struct FileChange: Sendable, Codable, Equatable {
        public enum Kind: Sendable, Equatable {
            case add
            case delete
            case update(movePath: String?)
        }
        public var path: String
        public var kind: Kind
        public var diff: String
        public init(path: String, kind: Kind, diff: String) {
            self.path = path; self.kind = kind; self.diff = diff
        }
        /// Back-compat convenience: accept the legacy string form
        /// (`"add"`/`"modify"`/`"update"`/`"delete"`).
        public init(path: String, kind: String, diff: String) {
            self.path = path; self.diff = diff
            switch kind {
            case "add": self.kind = .add
            case "delete": self.kind = .delete
            default: self.kind = .update(movePath: nil)   // "modify"/"update"
            }
        }

        private enum CodingKeys: String, CodingKey { case path, kind, diff }
        // Upstream `PatchChangeKind` is `#[serde(tag = "type", rename_all =
        // "camelCase")]`; serde's enum-level `rename_all` renames variant
        // NAMES only, NOT struct-variant FIELDS, so the `Update` field stays
        // snake_case `move_path` on the wire (confirmed by the generated TS
        // binding `{ "type": "update", move_path: string | null }`).
        private enum KindKeys: String, CodingKey { case type; case movePath = "move_path" }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(diff, forKey: .diff)
            var k = c.nestedContainer(keyedBy: KindKeys.self, forKey: .kind)
            switch kind {
            case .add: try k.encode("add", forKey: .type)
            case .delete: try k.encode("delete", forKey: .type)
            case .update(let mp):
                try k.encode("update", forKey: .type)
                // Upstream `PatchChangeKind::Update { move_path: Option<PathBuf> }`
                // has NO `skip_serializing_if`, so serde always emits the field —
                // `null` when absent. Use `encode` (not `encodeIfPresent`) so a
                // rename-less update serialises `{"type":"update","move_path":null}`.
                try k.encode(mp, forKey: .movePath)
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.path = try c.decode(String.self, forKey: .path)
            self.diff = try c.decode(String.self, forKey: .diff)
            // Tagged object form (current) with a tolerant bare-string fallback.
            if let k = try? c.nestedContainer(keyedBy: KindKeys.self, forKey: .kind) {
                let type = (try? k.decode(String.self, forKey: .type)) ?? "update"
                switch type {
                case "add": self.kind = .add
                case "delete": self.kind = .delete
                default: self.kind = .update(
                    movePath: try? k.decodeIfPresent(String.self, forKey: .movePath))
                }
            } else {
                let s = (try? c.decode(String.self, forKey: .kind)) ?? "update"
                switch s {
                case "add": self.kind = .add
                case "delete": self.kind = .delete
                default: self.kind = .update(movePath: nil)
                }
            }
        }
    }

    /// Upstream `CollabAgentTool` (app-server-protocol/v2/item.rs:910):
    /// `#[serde(rename_all = "camelCase")]` → `spawnAgent`/`sendInput`/
    /// `resumeAgent`/`wait`/`closeAgent`.
    public enum CollabAgentTool: String, Sendable, Codable, Equatable {
        case spawnAgent, sendInput, resumeAgent, wait, closeAgent
    }
    /// Upstream `CollabAgentToolCallStatus` (v2/item.rs:994).
    public enum CollabAgentToolCallStatus: String, Sendable, Codable, Equatable {
        case inProgress, completed, failed
    }
    /// Upstream `CollabAgentStatus` (v2/item.rs:1003).
    public enum CollabAgentStatus: String, Sendable, Codable, Equatable {
        case pendingInit, running, interrupted, completed, errored, shutdown, notFound
    }
    /// Upstream `CollabAgentState` (v2/item.rs:1016): `{ status, message }`.
    /// `message` is `Option<String>` with no `skip_serializing_if` → emitted as
    /// explicit `null` when absent.
    public struct CollabAgentState: Sendable, Codable, Equatable {
        public var status: CollabAgentStatus
        public var message: String?
        public init(status: CollabAgentStatus, message: String? = nil) {
            self.status = status; self.message = message
        }
        private enum CodingKeys: String, CodingKey { case status, message }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            try c.encode(message, forKey: .message)
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.status = try c.decode(CollabAgentStatus.self, forKey: .status)
            self.message = try c.decodeIfPresent(String.self, forKey: .message)
        }
    }

    public var id: ItemId {
        switch self {
        case .userMessage(let i, _), .agentMessage(let i, _), .reasoning(let i, _, _, _),
             .commandExecution(let i, _, _, _, _, _, _, _, _, _), .fileChange(let i, _, _),
             .collabAgentToolCall(let i, _, _, _, _, _, _, _, _),
             .contextMessage(let i, _, _),
             .contextCompaction(let i),
             .enteredReviewMode(let i, _),
             .exitedReviewMode(let i, _),
             .unknown(let i, _, _):
            return i
        }
    }

    /// On-wire discriminator string for this item — matches the JSON `type`
    /// field. Useful for logging/observability of `.unknown` items.
    public var typeName: String {
        switch self {
        case .userMessage: return "userMessage"
        case .agentMessage: return "agentMessage"
        case .reasoning: return "reasoning"
        case .commandExecution: return "commandExecution"
        case .fileChange: return "fileChange"
        case .collabAgentToolCall: return "collabAgentToolCall"
        case .contextMessage: return "contextMessage"
        case .contextCompaction: return "contextCompaction"
        case .enteredReviewMode: return "enteredReviewMode"
        case .exitedReviewMode: return "exitedReviewMode"
        case .unknown(_, let t, _): return t
        }
    }
}

extension ThreadItem: Codable {
    private enum K: String, CodingKey {
        case type, id, content, text, summary, command, cwd, status
        case phase, memoryCitation
        case commandActions
        case aggregatedOutput, exitCode, changes, role, sections, review
        case processId, source, durationMs
        case tool, senderThreadId, receiverThreadIds, prompt, model
        case reasoningEffort, agentsStates
    }
    public func encode(to encoder: any Encoder) throws {
        // `.unknown` round-trips the captured JSON verbatim — write it via a
        // single-value container so any extra fields (beyond `type`/`id`)
        // are preserved exactly as decoded. The other cases use a keyed
        // container.
        if case .unknown(let id, let typeName, let raw) = self {
            let merged: JSONValue = {
                if case .object(var fields) = raw {
                    fields["type"] = .string(typeName)
                    fields["id"] = .string(id.raw)
                    return .object(fields)
                }
                return .object(["type": .string(typeName), "id": .string(id.raw)])
            }()
            var single = encoder.singleValueContainer()
            try single.encode(merged)
            return
        }
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .userMessage(let id, let content):
            try c.encode("userMessage", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(content, forKey: .content)
        case .agentMessage(let id, let text):
            try c.encode("agentMessage", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            // Upstream `phase`/`memory_citation` are `#[serde(default)]` with no
            // `skip_serializing_if`, so serde ALWAYS emits them (`null` when
            // absent). Emit explicit `null` for byte-identical parity even though
            // this port does not currently surface either value.
            try c.encode(MessagePhase?.none, forKey: .phase)
            try c.encode(MemoryCitation?.none, forKey: .memoryCitation)
        case .reasoning(let id, let summary, let content, _):
            // `encryptedContent` is intentionally NOT serialized on the v2
            // frontend `ThreadItem` wire (upstream's v2 item carries only
            // `summary`/`content`). It is persisted separately in the rollout
            // (model `ResponseItem` shape) for cross-turn replay.
            try c.encode("reasoning", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(summary, forKey: .summary)
            try c.encode(content, forKey: .content)
        case .commandExecution(let id, let cmd, let cwd, let st, let actions, let out, let ec,
                               let pid, let source, let durationMs):
            try c.encode("commandExecution", forKey: .type)
            try c.encode(id, forKey: .id)
            // Upstream `command: String` (shlex-joined argv). The internal
            // representation is `[String]`; every emitter currently stores a
            // single already-joined command string, so joining with a space
            // yields the exact upstream wire value. A frontend decodes a
            // string here, not an array.
            try c.encode(cmd.joined(separator: " "), forKey: .command)
            try c.encode(cwd, forKey: .cwd)
            // Upstream `process_id: Option<String>` (no `skip_serializing_if`) →
            // always serialized, emit explicit JSON null when nil
            // (v2/item.rs:248-270, item_builders.rs:88-105).
            try c.encode(pid, forKey: .processId)
            // Upstream `source: CommandExecutionSource` (`#[serde(default)]`,
            // always serialized — defaults to "agent").
            try c.encode(source, forKey: .source)
            try c.encode(st, forKey: .status)
            // Upstream `command_actions: Vec<CommandAction>` is required and
            // always present (even if empty), so encode unconditionally.
            try c.encode(actions, forKey: .commandActions)
            // Upstream `aggregated_output: Option<String>` / `exit_code: Option<i32>`
            // / `duration_ms: Option<i64>` have NO `skip_serializing_if` → always
            // serialized, emit explicit JSON null when nil.
            try c.encode(out, forKey: .aggregatedOutput)
            try c.encode(ec, forKey: .exitCode)
            try c.encode(durationMs, forKey: .durationMs)
        case .fileChange(let id, let changes, let st):
            try c.encode("fileChange", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(changes, forKey: .changes)
            try c.encode(st, forKey: .status)
        case .collabAgentToolCall(let id, let tool, let st, let sender,
                                  let receivers, let prompt, let model,
                                  let effort, let states):
            try c.encode("collabAgentToolCall", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(tool, forKey: .tool)
            try c.encode(st, forKey: .status)
            try c.encode(sender, forKey: .senderThreadId)
            try c.encode(receivers, forKey: .receiverThreadIds)
            // Upstream `prompt`/`model`/`reasoning_effort` are `Option<_>` with no
            // `skip_serializing_if` → always serialized, emit explicit null.
            try c.encode(prompt, forKey: .prompt)
            try c.encode(model, forKey: .model)
            try c.encode(effort, forKey: .reasoningEffort)
            // `agents_states: HashMap<String, CollabAgentState>` — required map
            // (present even when empty).
            try c.encode(states, forKey: .agentsStates)
        case .contextMessage(let id, let role, let sections):
            try c.encode("contextMessage", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(role, forKey: .role)
            try c.encode(sections, forKey: .sections)
        case .contextCompaction(let id):
            try c.encode("contextCompaction", forKey: .type)
            try c.encode(id, forKey: .id)
        case .enteredReviewMode(let id, let review):
            try c.encode("enteredReviewMode", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(review, forKey: .review)
        case .exitedReviewMode(let id, let review):
            try c.encode("exitedReviewMode", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(review, forKey: .review)
        case .unknown:
            // Handled above via singleValueContainer — unreachable here.
            break
        }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try c.decode(ItemId.self, forKey: .id)
        switch type {
        case "userMessage":
            self = .userMessage(id: id, content: try c.decode([UserMessageContent].self, forKey: .content))
        case "agentMessage":
            // `phase` / `memoryCitation` are tolerated (and ignored) on decode —
            // upstream always sends them, usually as null. The modeled surface
            // stays `(id, text)`; see the `.agentMessage` doc comment.
            self = .agentMessage(id: id, text: try c.decode(String.self, forKey: .text))
        case "reasoning":
            // `summary`/`content` are arrays upstream; tolerate a legacy single
            // string by wrapping it. Default to empty arrays when absent.
            let summary: [String]
            if let arr = try? c.decodeIfPresent([String].self, forKey: .summary) {
                summary = arr ?? []
            } else if let s = try? c.decode(String.self, forKey: .summary) {
                summary = [s]
            } else {
                summary = []
            }
            let content = (try? c.decodeIfPresent([String].self, forKey: .content)) ?? [] ?? []
            self = .reasoning(id: id, summary: summary, content: content)
        case "commandExecution":
            // Upstream `command` is a single string; wrap it into the internal
            // `[String]` representation. Tolerate a legacy array form too.
            let command: [String]
            if let s = try? c.decode(String.self, forKey: .command) {
                command = [s]
            } else {
                command = (try? c.decode([String].self, forKey: .command)) ?? []
            }
            // `commandActions` is required upstream but tolerate its absence
            // (legacy payloads / older emitters) by defaulting to an empty list.
            let actions = (try? c.decodeIfPresent([CommandAction].self, forKey: .commandActions)) ?? [] ?? []
            // `source` is `#[serde(default)]` upstream → default `.agent` when
            // absent. `processId`/`durationMs` are optional (may be null/absent).
            let source = (try? c.decodeIfPresent(CommandExecutionSource.self, forKey: .source)) ?? nil ?? .agent
            self = .commandExecution(
                id: id,
                command: command,
                cwd: try c.decode(String.self, forKey: .cwd),
                status: try c.decode(ItemStatus.self, forKey: .status),
                commandActions: actions,
                aggregatedOutput: try c.decodeIfPresent(String.self, forKey: .aggregatedOutput),
                exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode),
                processId: try c.decodeIfPresent(String.self, forKey: .processId),
                source: source,
                durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs))
        case "fileChange":
            self = .fileChange(
                id: id,
                changes: try c.decode([FileChange].self, forKey: .changes),
                status: try c.decode(ItemStatus.self, forKey: .status))
        case "collabAgentToolCall":
            self = .collabAgentToolCall(
                id: id,
                tool: try c.decode(CollabAgentTool.self, forKey: .tool),
                status: try c.decode(CollabAgentToolCallStatus.self, forKey: .status),
                senderThreadId: try c.decode(String.self, forKey: .senderThreadId),
                receiverThreadIds: (try? c.decodeIfPresent([String].self, forKey: .receiverThreadIds)) ?? [] ?? [],
                prompt: try c.decodeIfPresent(String.self, forKey: .prompt),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                reasoningEffort: try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort),
                agentsStates: (try? c.decodeIfPresent([String: CollabAgentState].self, forKey: .agentsStates)) ?? [:] ?? [:])
        case "contextMessage":
            self = .contextMessage(
                id: id,
                role: try c.decode(String.self, forKey: .role),
                sections: try c.decode([String].self, forKey: .sections))
        case "contextCompaction":
            self = .contextCompaction(id: id)
        case "enteredReviewMode":
            self = .enteredReviewMode(
                id: id, review: try c.decode(String.self, forKey: .review))
        case "exitedReviewMode":
            self = .exitedReviewMode(
                id: id, review: try c.decode(String.self, forKey: .review))
        default:
            // Tolerant fallback: capture the whole JSON object so the item
            // can be re-emitted verbatim and inspected by future code.
            // We re-decode from the original decoder via a single-value
            // container — Foundation's JSONDecoder lets us layer this on top
            // of an already-opened keyed container because both views share
            // the same underlying value.
            let raw = try decoder.singleValueContainer().decode(JSONValue.self)
            self = .unknown(id: id, typeName: type, raw: raw)
        }
    }
}