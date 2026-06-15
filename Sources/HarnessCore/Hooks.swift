import Foundation
import Tools
import InfraPrimitives
import Observability
import Config
import WireProtocol
import ProtocolModel

// Module-level logger for hook-output validation warnings.
private let hookLog = Log(category: "HookEngine")

// MARK: - Event names (codex kebab wire strings)

public enum HookEventName: String, Sendable, Codable, Equatable, CaseIterable {
    case preToolUse
    case permissionRequest
    case postToolUse
    case preCompact
    case postCompact
    case sessionStart
    case userPromptSubmit
    case stop
    case subagentStart
    case subagentStop

    /// codex kebab-case wire string.
    public var wire: String {
        switch self {
        case .preToolUse:        return "pre-tool-use"
        case .permissionRequest: return "permission-request"
        case .postToolUse:       return "post-tool-use"
        case .preCompact:        return "pre-compact"
        case .postCompact:       return "post-compact"
        case .sessionStart:      return "session-start"
        case .userPromptSubmit:  return "user-prompt-submit"
        case .stop:              return "stop"
        case .subagentStart:     return "subagent-start"
        case .subagentStop:      return "subagent-stop"
        }
    }

    public var configKey: String {
        wire.replacingOccurrences(of: "-", with: "_")
    }

    /// PascalCase string that goes on stdin as `hook_event_name`. Matches
    /// upstream `codex_hooks::schema::HookEventNameWire` (`PreToolUse`,
    /// `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`,
    /// `SessionStart`, `UserPromptSubmit`, `Stop`). P4.6 / H-27.
    public var pascalCase: String {
        switch self {
        case .preToolUse:        return "PreToolUse"
        case .permissionRequest: return "PermissionRequest"
        case .postToolUse:       return "PostToolUse"
        case .preCompact:        return "PreCompact"
        case .postCompact:       return "PostCompact"
        case .sessionStart:      return "SessionStart"
        case .userPromptSubmit:  return "UserPromptSubmit"
        case .stop:              return "Stop"
        case .subagentStart:     return "SubagentStart"
        case .subagentStop:      return "SubagentStop"
        }
    }

    /// Upstream per-event "invalid JSON output" Failed-status message
    /// (`hooks/src/events/*.rs`, the `looks_like_json` parse-failure arm).
    /// Reproduced verbatim so `hook/completed` error entries match upstream.
    public var invalidJSONMessage: String {
        switch self {
        case .preToolUse:        return "hook returned invalid pre-tool-use JSON output"
        case .permissionRequest: return "hook returned invalid permission-request JSON output"
        case .postToolUse:       return "hook returned invalid post-tool-use JSON output"
        case .preCompact:        return "hook returned invalid PreCompact hook JSON output"
        case .postCompact:       return "hook returned invalid PostCompact hook JSON output"
        case .sessionStart:      return "hook returned invalid session start JSON output"
        case .userPromptSubmit:  return "hook returned invalid user prompt submit JSON output"
        case .stop:              return "hook returned invalid stop hook JSON output"
        case .subagentStart:     return "hook returned invalid subagent-start JSON output"
        case .subagentStop:      return "hook returned invalid subagent-stop JSON output"
        }
    }

    /// Accept the codex kebab wire form (`pre-tool-use`), the Swift
    /// camelCase form (`preToolUse`), the upstream snake_case config-key
    /// form (`pre_tool_use`), and PascalCase (`PreToolUse`), all
    /// case-insensitive. The trust-hash logic depends on `event_name`
    /// surviving parse for raw `hooks.json` entries written in any of
    /// these conventions.
    public static func from(wire raw: String) -> HookEventName? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for c in HookEventName.allCases
        where c.wire == s || c.rawValue == s || c.configKey == s {
            return c
        }
        let l = s.lowercased()
        for c in HookEventName.allCases
        where c.wire.lowercased() == l
              || c.rawValue.lowercased() == l
              || c.configKey.lowercased() == l {
            return c
        }
        return nil
    }
}

// MARK: - Hook definition (lenient codex JSON)

public struct HookDefinition: Sendable, Codable, Equatable {
    public var eventName: HookEventName
    public var matcher: String?
    public var command: String
    public var timeoutSec: UInt64
    /// Provenance for the `HookRunSummary` surfaced via `hook/started` /
    /// `hook/completed`. `sourcePath` is the declaring `hooks.json`;
    /// `source` is the v2 `HookSource` wire string (`user`/`project`/…).
    public var sourcePath: String
    public var source: String
    /// Stable, global discovery-time index. Upstream assigns this ONCE while
    /// walking the full handler set (every event, every config layer) in
    /// `engine/discovery.rs` (`let mut display_order = 0_i64;` … incremented
    /// per discovered command handler), and it is preserved verbatim through
    /// `select_handlers` into both `HookRunSummary.display_order` and the
    /// `run_id` (`{event_label}:{display_order}:{source_path}`,
    /// engine/mod.rs:55-62). It is NOT recomputed per fire. Assigned by the
    /// loader; defaults to 0 for ad-hoc definitions constructed in tests.
    public var displayOrder: Int
    /// The hook's declared `statusMessage` (config `statusMessage` /
    /// `status_message`). Upstream `ConfiguredHandler::status_message`
    /// (engine/discovery.rs:436/463/485) is surfaced verbatim on BOTH the
    /// `hook/started` and `hook/completed` `HookRunSummary.statusMessage`,
    /// regardless of run outcome (dispatcher.rs:79,132). `None`/absent in the
    /// common case; never derived from the run result.
    public var statusMessage: String?

    public init(eventName: HookEventName, matcher: String? = nil,
                command: String, timeoutSec: UInt64 = HookDefinition.defaultTimeoutSec,
                sourcePath: String = "", source: String = "unknown",
                displayOrder: Int = 0, statusMessage: String? = nil) {
        self.eventName = eventName
        self.matcher = matcher
        self.command = command
        self.timeoutSec = timeoutSec
        self.sourcePath = sourcePath
        self.source = source
        self.displayOrder = displayOrder
        self.statusMessage = statusMessage
    }

    /// Default hook timeout in seconds. Matches upstream codex-rs
    /// (`engine/discovery.rs::timeout_sec.unwrap_or(600).max(1)`). Only the
    /// lower bound is clamped in `runCommand()` (`max(timeoutSec, 1)`); a
    /// configured timeout above 600s is honored verbatim, matching upstream.
    public static let defaultTimeoutSec: UInt64 = 600
    public static let defaultTimeoutMillis: UInt64 = 600_000

    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init(_ s: String) { self.stringValue = s }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func str(_ keys: [String]) -> String? {
            for k in keys {
                if let v = try? c.decode(String.self, forKey: DynamicKey(k)) {
                    return v
                }
            }
            return nil
        }
        func uint(_ keys: [String]) -> UInt64? {
            for k in keys {
                let dk = DynamicKey(k)
                if let v = try? c.decode(UInt64.self, forKey: dk) { return v }
                if let v = try? c.decode(Double.self, forKey: dk) {
                    return UInt64(max(0, v))
                }
            }
            return nil
        }
        guard let ev = str(["event", "eventName", "event_name"]),
              let parsed = HookEventName.from(wire: ev) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "missing/invalid hook event name"))
        }
        guard let cmd = str(["command"]) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "missing hook command"))
        }
        self.eventName = parsed
        self.matcher = str(["matcher"])
        self.command = cmd
        self.timeoutSec = uint(["timeout", "timeoutSec", "timeout_sec"])
            ?? HookDefinition.defaultTimeoutSec
        // Provenance is assigned by the loader, not present in the hook JSON.
        self.sourcePath = str(["sourcePath", "source_path"]) ?? ""
        self.source = str(["source"]) ?? "unknown"
        // Assigned by the loader as a global discovery counter; the hook JSON
        // never carries it.
        self.displayOrder = 0
        // Configured handler statusMessage (config `statusMessage` /
        // `status_message`), surfaced verbatim on both summaries.
        self.statusMessage = str(["statusMessage", "status_message"])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(eventName.wire, forKey: DynamicKey("event"))
        if let matcher { try c.encode(matcher, forKey: DynamicKey("matcher")) }
        try c.encode(command, forKey: DynamicKey("command"))
        try c.encode(timeoutSec, forKey: DynamicKey("timeout"))
        if let statusMessage {
            try c.encode(statusMessage, forKey: DynamicKey("statusMessage"))
        }
    }
}

// MARK: - Decision / outcome / request

public enum HookDecision: String, Sendable, Equatable {
    case allow
    case block
}

/// Per-event `hookSpecificOutput` parsing result. Faithful to upstream
/// `codex_hooks::schema::{PreToolUse,PermissionRequest,PostToolUse,
/// SessionStart,UserPromptSubmit}HookSpecificOutputWire`.
///
/// Hooks may return *both* a top-level legacy `decision:block` and a nested
/// `hookSpecificOutput`; the two paths are independent in upstream and we
/// preserve that. Concretely: `permissionDecision` only applies to the new
/// `permission-decision` events (`PreToolUse`, `PermissionRequest`), while
/// `updatedInput` only applies to `PreToolUse` together with
/// `permissionDecision:allow`.
public struct HookSpecificOutput: Sendable, Equatable {
    public enum PermissionDecision: String, Sendable, Equatable {
        case allow
        case deny
        case ask
    }

    /// PreToolUse / PermissionRequest. For PermissionRequest this is derived
    /// from the nested `decision.behavior` (`allow`/`deny`).
    public var permissionDecision: PermissionDecision?
    public var permissionDecisionReason: String?
    /// PreToolUse only: a tool-input rewrite. Carried as the canonical-JSON
    /// string the hook emitted (sorted-keys, no whitespace). Callers re-decode
    /// to drive the tool dispatcher. String is used instead of `[String: Any]`
    /// so the type remains `Sendable` (Foundation `Any` is not).
    public var updatedInputJSON: String?
    /// PostToolUse / SessionStart / UserPromptSubmit / PreToolUse: structured
    /// context that the harness injects into the next model turn.
    public var additionalContext: String?
    /// PermissionRequest deny message (carried separately from
    /// `permissionDecisionReason` because upstream's wire shape is different
    /// for that one event).
    public var permissionDenyMessage: String?

    public init(permissionDecision: PermissionDecision? = nil,
                permissionDecisionReason: String? = nil,
                updatedInputJSON: String? = nil,
                additionalContext: String? = nil,
                permissionDenyMessage: String? = nil) {
        self.permissionDecision = permissionDecision
        self.permissionDecisionReason = permissionDecisionReason
        self.updatedInputJSON = updatedInputJSON
        self.additionalContext = additionalContext
        self.permissionDenyMessage = permissionDenyMessage
    }
}

public struct HookOutcome: Sendable, Equatable {
    public var decision: HookDecision
    public var reason: String?
    public var systemMessage: String?
    public var additionalContext: String?
    /// Per-event structured output (`hookSpecificOutput`). Upstream protocol;
    /// flat legacy keys remain readable via `decision` / `reason` /
    /// `additionalContext` for back-compat with older hooks.
    public var hookSpecificOutput: HookSpecificOutput?
    /// P4.6 / H-29, H-40 — Stop-hook semantic. Upstream distinguishes
    /// `continue: false` (terminate the session) from `decision: "block"`
    /// (inject a continuation prompt and re-enter sampling). Pre-P4.6 both
    /// collapsed to `HookDecision.block`, discarding the difference and the
    /// continuation prompt. These fields preserve both signals so the
    /// SessionEngine's Stop-hook handler can act on them.
    ///
    /// Semantics:
    ///   - `shouldStop == true`  → terminate session (continue:false).
    ///   - `shouldBlock == true` → re-enter sampling loop with
    ///     `continuationPrompt` injected as a user-role message.
    ///   - `shouldStop` wins over `shouldBlock` (upstream
    ///     `events/stop.rs::aggregate_results`).
    public var shouldStop: Bool
    public var stopReason: String?
    public var shouldBlock: Bool
    public var continuationPrompt: String?
    /// P4.5 / F3, F4 — partial mirror of upstream `HookRunStatus::Failed`.
    /// When a hook produces output that violates the per-event schema
    /// (e.g. `permissionDecision:allow` without `updatedInput`,
    /// `permissionDecision:deny` without a non-empty
    /// `permissionDecisionReason`, or `permissionDecision:ask`), upstream
    /// sets the hook's run status to `Failed` and pushes a
    /// `HookOutputEntryKind::Error` with the same message we emit via the
    /// `HookEngine` warn logger. Swift currently has no `runStatus` enum on
    /// the outcome, so we surface the human-readable schema-violation
    /// message here. Nil when the hook output was schema-valid (or when no
    /// JSON was emitted at all). Callers that want upstream-faithful
    /// "hook failed" semantics can branch on this field; the legacy
    /// `decision`/`shouldBlock`/`reason` triple is preserved untouched so
    /// existing callers keep working.
    public var outputSchemaError: String?
    /// H-hooks F8 — PostToolUse model FEEDBACK. Upstream's PostToolUse parser
    /// distinguishes `feedback_messages_for_model` (rendered as a
    /// `HookOutputEntryKind::Feedback` entry and used to replace the tool
    /// output text, post_tool_use.rs:256-269) from `additional_contexts_for_model`
    /// (rendered as `Context` and injected as developer messages,
    /// common::append_additional_context). The exit-2 stderr arm pushes a
    /// `Feedback` entry — NOT a `Context` entry. Carrying it here lets
    /// summarize() emit the correct `feedback` kind while the SessionEngine
    /// still threads it to the model.
    public var feedbackMessage: String?
    public var raw: String

    public init(decision: HookDecision, reason: String? = nil,
                systemMessage: String? = nil, additionalContext: String? = nil,
                hookSpecificOutput: HookSpecificOutput? = nil,
                shouldStop: Bool = false, stopReason: String? = nil,
                shouldBlock: Bool = false, continuationPrompt: String? = nil,
                outputSchemaError: String? = nil,
                feedbackMessage: String? = nil,
                raw: String = "") {
        self.decision = decision
        self.reason = reason
        self.systemMessage = systemMessage
        self.additionalContext = additionalContext
        self.hookSpecificOutput = hookSpecificOutput
        self.shouldStop = shouldStop
        self.stopReason = stopReason
        self.shouldBlock = shouldBlock
        self.continuationPrompt = continuationPrompt
        self.outputSchemaError = outputSchemaError
        self.feedbackMessage = feedbackMessage
        self.raw = raw
    }
}

public struct HookRequest: Sendable, Equatable {
    public var eventName: HookEventName
    public var sessionId: String
    public var cwd: String
    public var toolName: String?
    public var toolArgumentsJSON: String?
    /// PostToolUse `tool_response`. Wire field is `tool_response` (P4.6 /
    /// H-28). The legacy Swift name "toolOutput" is preserved here because
    /// every caller threads the same value through it.
    public var toolOutput: String?
    public var prompt: String?
    /// P4.6 / H-28 — common fields upstream sends on every event:
    /// `turn_id`, `model`, `permission_mode`, `transcript_path`.
    /// `turnId` is omitted for SessionStart (upstream `SessionStartCommandInput`
    /// has no `turn_id`).
    public var turnId: String?
    public var model: String?
    public var permissionMode: String?
    public var transcriptPath: String?
    /// SessionStart-only: one of `startup`, `resume`, `clear`. Upstream
    /// matcher input for session-start hooks.
    public var source: String?
    /// Stop-only: whether the current stop is itself a re-entry triggered by
    /// a previous Stop hook's continuation prompt (upstream
    /// `StopCommandInput.stop_hook_active`).
    public var stopHookActive: Bool?
    /// Stop-only: the last assistant message produced before the Stop hook
    /// fires (nullable on the wire).
    public var lastAssistantMessage: String?
    /// PreToolUse / PostToolUse: the active tool-call id. Upstream
    /// `PreToolUseCommandInput.tool_use_id` / `PostToolUseCommandInput.tool_use_id`
    /// are REQUIRED (non-optional) fields (hooks/src/schema.rs:242-256,279-294),
    /// always emitted on the hook stdin payload for those two events.
    public var toolUseId: String?
    /// PermissionRequest-only: the run-id suffix appended to the
    /// `HookRunSummary.id` (upstream `PermissionRequestRequest.run_id_suffix`,
    /// hooks/src/events/permission_request.rs:44). Upstream callers supply the
    /// tool `call_id` / guardian-approval-id here (core/src/hook_runtime.rs:208).
    /// For PreToolUse / PostToolUse the suffix is `toolUseId`; this field is
    /// only consulted for PermissionRequest.
    public var runIdSuffix: String?
    /// PreToolUse / PostToolUse / PermissionRequest: compatibility matcher
    /// aliases tested IN ADDITION to the canonical tool name. Upstream
    /// `HookToolName.matcher_aliases` (core/src/tools/hook_names.rs:34-39):
    /// `apply_patch` carries `["Write", "Edit"]` so Claude-Code-style hook
    /// matchers select on apply_patch tool calls. Threaded into the matcher
    /// input set by `common::matcher_inputs` (hooks/src/events/common.rs:137-146)
    /// and consulted by `dispatcher::select_handlers_for_matcher_inputs`
    /// (hooks/src/engine/dispatcher.rs:57-60). The canonical name still wins on
    /// the hook stdin payload (`tool_name`); aliases only affect SELECTION.
    public var matcherAliases: [String]
    public var extra: [String: String]

    public init(eventName: HookEventName, sessionId: String, cwd: String,
                toolName: String? = nil, toolArgumentsJSON: String? = nil,
                toolOutput: String? = nil, prompt: String? = nil,
                turnId: String? = nil, model: String? = nil,
                permissionMode: String? = nil, transcriptPath: String? = nil,
                source: String? = nil, stopHookActive: Bool? = nil,
                lastAssistantMessage: String? = nil,
                toolUseId: String? = nil,
                runIdSuffix: String? = nil,
                matcherAliases: [String] = [],
                extra: [String: String] = [:]) {
        self.eventName = eventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolArgumentsJSON = toolArgumentsJSON
        self.toolOutput = toolOutput
        self.prompt = prompt
        self.turnId = turnId
        self.model = model
        self.permissionMode = permissionMode
        self.transcriptPath = transcriptPath
        self.source = source
        self.stopHookActive = stopHookActive
        self.lastAssistantMessage = lastAssistantMessage
        self.toolUseId = toolUseId
        self.runIdSuffix = runIdSuffix
        self.matcherAliases = matcherAliases
        self.extra = extra
    }

    /// The run-id suffix appended to `HookRunSummary.id` for tool-scoped
    /// events (upstream `common::hook_run_for_tool_use`,
    /// hooks/src/events/common.rs:93-95). PreToolUse / PostToolUse append the
    /// `tool_use_id`; PermissionRequest appends `run_id_suffix`. All other
    /// events have no suffix.
    public var hookRunIdSuffix: String? {
        switch eventName {
        case .preToolUse, .postToolUse:
            // Upstream `tool_use_id` is a non-optional `String`, so the suffix
            // is ALWAYS appended (empty string when the caller didn't thread an
            // id, yielding a trailing `:`), matching `format!("{}:{tool_use_id}", id)`.
            return toolUseId ?? extra["tool_use_id"] ?? ""
        case .permissionRequest:
            // Upstream `run_id_suffix` is a non-optional `String`; always append.
            return runIdSuffix ?? ""
        case .preCompact, .postCompact, .sessionStart,
             .userPromptSubmit, .stop, .subagentStart, .subagentStop:
            return nil
        }
    }

    /// Upstream `matcher_pattern_for_event` + per-event matcher inputs decide
    /// what string the hook matcher is tested against:
    ///   - PreToolUse / PermissionRequest / PostToolUse → the tool name
    ///     (`common::matcher_inputs`, events/{pre,post}_tool_use.rs,
    ///     permission_request.rs).
    ///   - SessionStart → the session `source` (startup/resume/clear)
    ///     (events/session_start.rs:66-70).
    ///   - PreCompact / PostCompact → the compaction `trigger` (manual/auto),
    ///     threaded through `extra["trigger"]` (events/compact.rs:59-62,138-141).
    ///   - UserPromptSubmit / Stop → `None`: the matcher is ignored entirely
    ///     (events/user_prompt_submit.rs:51-55, stop.rs:57). Upstream
    ///     `dispatcher::select_handlers_for_matcher_inputs` short-circuits these
    ///     two events to `=> true` (dispatcher.rs:62) WITHOUT calling
    ///     `matches_matcher`, so `matches(...)` returns true for them regardless
    ///     of this value; the nil result here merely documents "no matcher
    ///     input".
    /// Returns nil when there is no matcher input for the event.
    public var matchString: String? {
        switch eventName {
        case .preToolUse, .permissionRequest, .postToolUse:
            return toolName ?? ""
        case .sessionStart:
            return source ?? ""
        case .preCompact, .postCompact:
            return extra["trigger"] ?? ""
        case .userPromptSubmit, .stop, .subagentStart, .subagentStop:
            // Subagent hooks carry no matcher input — the dispatcher fires them
            // for every subagent lifecycle event (like Stop/UserPromptSubmit).
            return nil
        }
    }

    /// The full ordered set of matcher inputs a tool-scoped matcher is tested
    /// against — the canonical name first, then any compatibility aliases.
    /// Faithful to upstream `common::matcher_inputs`
    /// (hooks/src/events/common.rs:137-146): `std::iter::once(tool_name)
    /// .chain(matcher_aliases)`. For non-tool events (which carry no aliases)
    /// this is just `[matchString]` (or `[]` when `matchString` is nil, the
    /// UserPromptSubmit / Stop case that the dispatcher short-circuits anyway).
    public var matchInputs: [String] {
        guard let base = matchString else { return [] }
        switch eventName {
        case .preToolUse, .permissionRequest, .postToolUse:
            return [base] + matcherAliases
        default:
            return [base]
        }
    }

    /// Stable JSON object written to the hook command's stdin. Faithful to
    /// upstream `codex_hooks::schema::*CommandInput` (P4.6 / H-27, H-28):
    /// `hook_event_name` is PascalCase; turn-scoped events include `turn_id`,
    /// `model`, `permission_mode`, `transcript_path`; SessionStart sends
    /// `source`; Stop sends `stop_hook_active` + `last_assistant_message`;
    /// PostToolUse sends `tool_response` (not `tool_output`).
    public func jsonObject() -> [String: Any] {
        var o: [String: Any] = [
            "hook_event_name": eventName.pascalCase,
            "session_id": sessionId,
            "cwd": cwd,
        ]
        // Common turn-scoped fields. SessionStart omits `turn_id`.
        if eventName != .sessionStart {
            o["turn_id"] = turnId ?? ""
        }
        o["model"] = model ?? ""
        // Upstream `PreCompactCommandInput` / `PostCompactCommandInput`
        // (hooks/src/schema.rs:296-326) carry only session_id, turn_id,
        // transcript_path, cwd, hook_event_name, model, trigger — there is NO
        // `permission_mode` on the compact inputs. Every other turn-scoped
        // event includes it.
        if eventName != .preCompact && eventName != .postCompact {
            o["permission_mode"] = permissionMode ?? "default"
        }
        // Upstream emits `transcript_path: null` when unset; we serialize it
        // as NSNull so JSONSerialization writes a literal `null`.
        if let transcriptPath {
            o["transcript_path"] = transcriptPath
        } else {
            o["transcript_path"] = NSNull()
        }
        if let toolName { o["tool_name"] = toolName }
        if let toolArgumentsJSON {
            if let d = toolArgumentsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) {
                o["tool_input"] = parsed
            } else {
                o["tool_input"] = toolArgumentsJSON
            }
        }
        // PreToolUse / PostToolUse carry a REQUIRED `tool_use_id` on the wire
        // (hooks/src/schema.rs:242-256,279-294). Emit it unconditionally for
        // those two events; empty string when the caller didn't thread an id.
        if eventName == .preToolUse || eventName == .postToolUse {
            o["tool_use_id"] = toolUseId ?? extra["tool_use_id"] ?? ""
        }
        // PostToolUse: upstream key is `tool_response` (P4.6 / H-28).
        if eventName == .postToolUse, let toolOutput {
            if let d = toolOutput.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) {
                o["tool_response"] = parsed
            } else {
                o["tool_response"] = toolOutput
            }
        } else if let toolOutput {
            // Pre-P4.6 callers passed `toolOutput` for non-PostToolUse cases;
            // preserve their behaviour under the legacy key so we don't
            // silently drop the field.
            o["tool_output"] = toolOutput
        }
        if let prompt { o["prompt"] = prompt }
        if eventName == .sessionStart {
            o["source"] = source ?? "startup"
        }
        // Stop AND SubagentStop carry stop_hook_active + last_assistant_message
        // (upstream `StopCommandInput` / `SubagentStopCommandInput`). The
        // subagent-only fields agent_id / agent_type / agent_transcript_path are
        // threaded through `extra` and merged below.
        if eventName == .stop || eventName == .subagentStop {
            o["stop_hook_active"] = stopHookActive ?? false
            if let lastAssistantMessage {
                o["last_assistant_message"] = lastAssistantMessage
            } else {
                o["last_assistant_message"] = NSNull()
            }
        }
        for (k, v) in extra { o[k] = v }
        return o
    }
}

// MARK: - Engine

public actor HookEngine {
    private var hooks: [HookDefinition]
    private var legacyNotifyArgv: [String]?
    private let reaper: @Sendable (Int32) -> Void

    public init(hooks: [HookDefinition] = [],
                legacyNotifyArgv: [String]? = nil,
                reaper: @escaping @Sendable (Int32) -> Void = { reapProcessTree($0) }) {
        self.hooks = hooks
        self.legacyNotifyArgv = legacyNotifyArgv
        self.reaper = reaper
    }

    private struct HooksFile: Decodable { let hooks: [HookDefinition] }

    /// Read `$CODEX_HOME/hooks.json` then `<cwd>/.codex/hooks.json`. Each
    /// file is either `{"hooks":[...]}` or a bare `[...]`. Missing/malformed
    /// files are ignored (lenient); home definitions come first. Unmanaged
    /// hooks must be enabled and have `hooks.state.<key>.trusted_hash` equal
    /// to their current definition hash before they become runnable.
    ///
    /// Trust hash compatibility:
    /// - **Primary (P4.7 / H-30)**: `sha256:<hex>` of the canonical-JSON
    ///   encoding of the normalized hook identity, matching upstream
    ///   `codex_config::version_for_toml(NormalizedHookIdentity)` byte-for-byte
    ///   (see `currentHookHash`). This is what the Rust client writes; without
    ///   this scheme cross-process trust never matched.
    /// - **Backward-compat fallback**: `fnv64:<hex>` of the raw JSON object,
    ///   the legacy Swift-only algorithm. Hashes already persisted by older
    ///   builds keep verifying so users don't lose trust on upgrade. New
    ///   trust writes (handled outside the engine, in the UI) should use
    ///   `currentHookHash`.
    public static func load(codexHome: String, cwd: String,
                            legacyNotifyArgv: [String]? = nil) -> HookEngine {
        let state = hookState(codexHome: codexHome)
        // Global discovery-time counter, incremented once per discovered
        // command handler across BOTH files (home then project), exactly like
        // upstream `discovery::discover_handlers` (`let mut display_order = 0`).
        // It advances for every command handler that survives the
        // empty/non-command checks — including ones later dropped for
        // disabled/untrusted state — so the value assigned to a runnable hook
        // matches what the Rust client computes.
        var displayOrderCounter = 0
        func parse(_ data: Data, path: String, source: String,
                   displayOrder: inout Int) -> [HookDefinition] {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return []
            }
            // Each candidate carries the upstream (group_index, handler_index)
            // pair so the persisted trust key matches `codex_hooks::hook_key`
            // (`{path}:{snake_event}:{group_index}:{handler_index}`,
            // hooks/src/lib.rs:91-101).
            var rawHooks: [(raw: JSONValue, groupIndex: Int, handlerIndex: Int)] = []
            if let topArray = value["hooks"]?.arrayValue ?? value.arrayValue {
                // Legacy flat-array form (Swift-only convenience): each entry is
                // its own group with a single handler. Preserve the historical
                // key generation — running array index as group_index, 0 as
                // handler_index — which is what older state files were written
                // against.
                for (idx, raw) in topArray.enumerated() {
                    rawHooks.append((raw, idx, 0))
                }
            } else if case .object(let eventsMap)? = value["hooks"] {
                // Canonical upstream grouped-object form (config/src/hooks.rs
                // `HookEventsToml`): `hooks` is a MAP from EventName →
                // [{ matcher, hooks: [{type:"command", command, timeout,
                // statusMessage}] }]. group_index enumerates the matcher-groups
                // WITHIN one event and handler_index enumerates the handlers
                // WITHIN that group (discovery.rs:418-472). Both enumerations
                // count every group / handler (including skipped non-command or
                // empty ones) so the index positions stay aligned with the
                // state file the Rust client wrote.
                // Upstream `HookEventsToml::into_matcher_groups`
                // (config/src/hook_config.rs) yields events in a FIXED struct
                // order, not the JSON map's insertion order:
                // pre_tool_use, permission_request, post_tool_use, pre_compact,
                // post_compact, session_start, user_prompt_submit, stop. This
                // ordering drives the global `display_order` counter, so we
                // iterate `HookEventName.allCases` (declared in that same order)
                // rather than the dictionary's arbitrary key order.
                for canonical in HookEventName.allCases {
                    // The JSON map keys are the v2 wire/config strings; resolve
                    // each declared key to its canonical event and only process
                    // entries belonging to the current canonical event.
                    let matchedKeys = eventsMap.keys.filter {
                        normalizedHookEventName($0) == canonical.configKey
                            || HookEventName.from(wire: $0) == canonical
                    }
                    for eventKey in matchedKeys.sorted() {
                        guard case .array(let groups)? = eventsMap[eventKey] else { continue }
                        let eventName = eventKey
                        for (groupIndex, g) in groups.enumerated() {
                        let matcher = g["matcher"]?.stringValue
                        guard case .array(let handlers)? = g["hooks"] else { continue }
                        for (handlerIndex, h) in handlers.enumerated() {
                            // Only `command`-type handlers run, but a skipped
                            // non-command/empty handler still consumes its
                            // handler_index upstream — so we `continue` without
                            // resetting the enumeration counter.
                            if let type = h["type"]?.stringValue, type != "command" { continue }
                            let cmd = h["command"]?.stringValue ?? ""
                            guard !cmd.isEmpty else { continue }
                            var obj: [String: JSONValue] = [
                                "event": .string(eventName),
                                "command": .string(cmd),
                            ]
                            if let m = matcher { obj["matcher"] = .string(m) }
                            if let t = h["timeout"]?.intValue { obj["timeout"] = .int(t) }
                            // Configured handler statusMessage (discovery.rs:436);
                            // surfaced verbatim on both hook/started + hook/completed.
                            if let sm = h["statusMessage"]?.stringValue
                                ?? h["status_message"]?.stringValue {
                                obj["statusMessage"] = .string(sm)
                            }
                            rawHooks.append((.object(obj), groupIndex, handlerIndex))
                        }
                        }
                    }
                }
            }
            let dec = JSONDecoder()
            var out: [HookDefinition] = []
            for (raw, groupIndex, handlerIndex) in rawHooks {
                guard let object = raw.objectValue,
                      let encoded = try? JSONEncoder().encode(raw),
                      var def = try? dec.decode(HookDefinition.self, from: encoded) else {
                    continue
                }
                // Provenance for the v2 HookRunSummary surfaced via
                // hook/started + hook/completed.
                def.sourcePath = path
                def.source = source
                // Assign the global discovery index, then advance the counter
                // for every command handler (upstream increments after pushing
                // the entry, regardless of enabled/trusted state — discovery.rs:514).
                def.displayOrder = displayOrder
                displayOrder += 1
                let event = object["event"]?.stringValue
                    ?? object["eventName"]?.stringValue
                    ?? object["event_name"]?.stringValue
                    ?? def.eventName.rawValue
                let eventName = normalizedHookEventName(event) ?? def.eventName.configKey
                let key = "\(path):\(eventName):\(groupIndex):\(handlerIndex)"
                let entry = state[key]
                let enabled = entry?["enabled"]?.boolValue ?? true
                let canonicalHash = currentHookHash(def)
                let legacyHash = legacyHookHash(object)
                let trustedHash = entry?["trusted_hash"]?.stringValue
                let trusted = trustedHash != nil
                    && (trustedHash == canonicalHash || trustedHash == legacyHash)
                if enabled, trusted {
                    out.append(def)
                }
            }
            return out
        }
        func read(_ path: String, source: String) -> [HookDefinition] {
            guard let d = FileManager.default.contents(atPath: path) else { return [] }
            return parse(d, path: path, source: source, displayOrder: &displayOrderCounter)
        }
        var defs: [HookDefinition] = []
        let homeFile = (codexHome as NSString)
            .appendingPathComponent("hooks.json")
        let cwdFile = ((cwd as NSString)
            .appendingPathComponent(".codex") as NSString)
            .appendingPathComponent("hooks.json")
        // $CODEX_HOME/hooks.json → user layer; <cwd>/.codex/hooks.json → project.
        defs.append(contentsOf: read(homeFile, source: "user"))
        defs.append(contentsOf: read(cwdFile, source: "project"))
        return HookEngine(hooks: defs, legacyNotifyArgv: legacyNotifyArgv)
    }

    // MARK: - Trust hashes (P4.7 / H-30)

    /// Compatibility alias retained for older test fixtures and any external
    /// callers (e.g. CLI tooling) that previously wrote FNV-64 trusted_hash
    /// values. Internally `load()` now ALSO accepts the legacy form so trust
    /// upgrades smoothly without invalidating already-trusted hooks.
    public static func stableHookHash(_ object: [String: JSONValue]) -> String {
        legacyHookHash(object)
    }

    /// Legacy FNV-64a hash over the sorted-key JSON encoding of the raw hook
    /// object. Format: `"fnv64:<hex>"`. Kept as a fallback ONLY to honor
    /// trust grants written by previous Swift builds; new code should use
    /// `currentHookHash`.
    public static func legacyHookHash(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(object))) ?? Data()
        return "fnv64:" + fnv64Hex(data)
    }

    /// Upstream-compatible hook trust hash. Format: `"sha256:<hex>"`.
    ///
    /// Mirrors `codex_config::version_for_toml(NormalizedHookIdentity)` in
    /// `codex-rs/config/src/fingerprint.rs`:
    ///
    /// 1. Build the normalized identity:
    ///    `{ event_name, matcher?, hooks: [HookHandlerConfig::Command] }`.
    /// 2. Convert to JSON (TOML semantics: `None` options are omitted).
    /// 3. Canonicalize: recursively sort all object keys.
    /// 4. Serialize to bytes via `JSONSerialization` (no whitespace).
    /// 5. SHA-256, hex-lowercase, prefixed with `"sha256:"`.
    ///
    /// The TOML round-trip in upstream is byte-equivalent to this direct
    /// canonical-JSON path (verified against
    /// `cargo run -p codex-config --example hookhash`):
    ///   - fixture `(pre_tool_use, "Bash", "echo hi", 60)` →
    ///     `sha256:d5030d2a3c704b4a75fe25c5c7a47a1010ada427d56d9bb6c83aa830ce07ce90`
    ///   - fixture `(session_start, nil, "a", 60)` →
    ///     `sha256:e5e616cbaede3a46f84e7c45123309343cfa00f149ec622ac64785799b23b54c`
    public static func currentHookHash(_ def: HookDefinition) -> String {
        // Build the canonical-JSON object. Keys here must EXACTLY match the
        // upstream serde renames in `codex_config::HookHandlerConfig::Command`
        // and `MatcherGroup`. `#[serde(flatten)]` on `group` puts `matcher`
        // and `hooks` at the top level next to `event_name`.
        var handler: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(def.command),
            "async": .bool(false),
        ]
        // `timeout` is `Option<u64>` in Rust; we always emit it because the
        // discovery layer canonicalizes via `Some(timeout.unwrap_or(600))`
        // before hashing. Sending None on our side would diverge from the
        // upstream hash for an otherwise-identical hook.
        handler["timeout"] = .int(Int64(clamping: def.timeoutSec))
        // `statusMessage` is part of the normalized handler upstream hashes
        // (discovery.rs:463 `status_message: status_message.clone()`), but a
        // `None`/absent value is dropped by the TOML round-trip — so we emit it
        // only when set, mirroring upstream's TOML-dropped Nones.
        if let sm = def.statusMessage {
            handler["statusMessage"] = .string(sm)
        }
        // command_windows is always None in our config shape today; omit it to
        // match upstream's TOML-dropped Nones.

        var obj: [String: JSONValue] = [
            "event_name": .string(def.eventName.configKey),
            "hooks": .array([.object(handler)]),
        ]
        if let m = def.matcher { obj["matcher"] = .string(m) }
        return canonicalSha256(.object(obj))
    }

    /// Same as `currentHookHash` but accepts a raw JSON hook object — i.e.
    /// the parsed entry exactly as it appears in `hooks.json`. Used during
    /// trust-list display and by load() to compare against persisted hashes
    /// without round-tripping through `HookDefinition` (which would lose
    /// fields like `commandWindows` if we ever start respecting them).
    public static func currentHookHash(_ object: [String: JSONValue]) -> String {
        let dec = JSONDecoder()
        guard let encoded = try? JSONEncoder().encode(JSONValue.object(object)),
              let def = try? dec.decode(HookDefinition.self, from: encoded) else {
            // Object isn't a valid hook; degrade to an empty handler so the
            // hash is at least deterministic and clearly non-matching.
            return canonicalSha256(.object([
                "event_name": .string(""),
                "hooks": .array([]),
            ]))
        }
        return currentHookHash(def)
    }

    private static func canonicalSha256(_ value: JSONValue) -> String {
        let bytes = canonicalJSONBytes(value)
        let digest = SHA256.hash(bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    /// Emit JSON bytes with recursively-sorted object keys, matching
    /// `serde_json::to_vec(canonical_json(v))` in upstream's
    /// `fingerprint::canonical_json`. The encoding is the standard JSON
    /// minimal form: no whitespace, `\n`/`\t` escapes for control chars,
    /// numbers without trailing zeros.
    static func canonicalJSONBytes(_ value: JSONValue) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        encodeCanonical(value, into: &out)
        return out
    }

    private static func encodeCanonical(_ value: JSONValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let b):
            out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let i):
            out.append(contentsOf: String(i).utf8)
        case .double(let d):
            // Mirror serde_json: integral doubles are emitted with a
            // ".0" suffix, NaN/Inf are not legal JSON (default to null).
            if d.isNaN || d.isInfinite {
                out.append(contentsOf: "null".utf8)
            } else if d == d.rounded(), abs(d) < 1e16 {
                out.append(contentsOf: String(format: "%.1f", d).utf8)
            } else {
                out.append(contentsOf: String(d).utf8)
            }
        case .string(let s):
            encodeJSONString(s, into: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (idx, item) in a.enumerated() {
                if idx > 0 { out.append(UInt8(ascii: ",")) }
                encodeCanonical(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            let keys = o.keys.sorted()
            for (idx, k) in keys.enumerated() {
                if idx > 0 { out.append(UInt8(ascii: ",")) }
                encodeJSONString(k, into: &out)
                out.append(UInt8(ascii: ":"))
                encodeCanonical(o[k]!, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func encodeJSONString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":
                out.append(contentsOf: [0x5C, 0x22]) // \"
            case "\\":
                out.append(contentsOf: [0x5C, 0x5C]) // \\
            case "\u{08}":
                out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case "\u{0C}":
                out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case "\n":
                out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case "\r":
                out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case "\t":
                out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            default:
                if scalar.value < 0x20 {
                    let hex = String(format: "\\u%04x", scalar.value)
                    out.append(contentsOf: hex.utf8)
                } else {
                    out.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    private static func fnv64Hex(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    // MARK: - Inlined SHA-256 (FIPS 180-4)
    //
    // HarnessCore deliberately avoids adding an Auth dependency for a single
    // hash. This is the same allocation-light implementation as
    // `Auth/SHA256.swift`, kept private here so the hooks engine stays
    // self-contained.
    fileprivate enum SHA256 {
        private static let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
            0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
            0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
            0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
            0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }
        static func hash(_ message: [UInt8]) -> [UInt8] {
            var h: [UInt32] = [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            ]
            var msg = message
            let bitLen = UInt64(message.count) * 8
            msg.append(0x80)
            while msg.count % 64 != 56 { msg.append(0) }
            for i in (0..<8).reversed() {
                msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff))
            }
            var w = [UInt32](repeating: 0, count: 64)
            var block = 0
            while block < msg.count {
                for i in 0..<16 {
                    let j = block + i * 4
                    w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16)
                        | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
                }
                for i in 16..<64 {
                    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var a = h[0], b = h[1], c = h[2], d = h[3]
                var e = h[4], f = h[5], g = h[6], hh = h[7]
                for i in 0..<64 {
                    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    hh = g; g = f; f = e; e = d &+ t1
                    d = c; c = b; b = a; a = t1 &+ t2
                }
                h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
                h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
                block += 64
            }
            var out = [UInt8]()
            out.reserveCapacity(32)
            for v in h {
                out.append(UInt8((v >> 24) & 0xff))
                out.append(UInt8((v >> 16) & 0xff))
                out.append(UInt8((v >> 8) & 0xff))
                out.append(UInt8(v & 0xff))
            }
            return out
        }
    }

    private static func hookState(codexHome: String) -> [String: [String: ConfigValue]] {
        let path = codexHome + "/config.toml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let config = try? TOML.parse(text),
              case .object(let hooks)? = config["hooks"],
              case .object(let state)? = hooks["state"] else {
            return [:]
        }
        var out: [String: [String: ConfigValue]] = [:]
        for (key, value) in state {
            guard case .object(let entry) = value else { continue }
            out[key] = entry
        }
        return out
    }

    private static func normalizedHookEventName(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
        let lower = normalized.lowercased()
        let known: [String: String] = [
            "pre_tool_use": "pre_tool_use",
            "permission_request": "permission_request",
            "post_tool_use": "post_tool_use",
            "pre_compact": "pre_compact",
            "post_compact": "post_compact",
            "session_start": "session_start",
            "user_prompt_submit": "user_prompt_submit",
            "stop": "stop",
        ]
        if let event = known[lower] { return event }
        let camel = raw.reduce(into: "") { partial, char in
            if char.isUppercase { partial.append("_") }
            partial.append(char.lowercased())
        }.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return known[camel]
    }

    public func add(_ defs: [HookDefinition]) { hooks.append(contentsOf: defs) }
    public func setLegacyNotifyArgv(_ argv: [String]?) { legacyNotifyArgv = argv }
    public func definitions() -> [HookDefinition] { hooks }

    private func matches(_ def: HookDefinition, _ req: HookRequest) -> Bool {
        guard def.eventName == req.eventName else { return false }
        // Faithful port of `dispatcher::select_handlers_for_matcher_inputs`
        // (hooks/src/engine/dispatcher.rs:47-63): UserPromptSubmit and Stop
        // ALWAYS fire — their arm is `=> true`, the matcher is never consulted
        // (`matches_matcher` is not even called). Every other event tests its
        // matcher against the per-event input string (nil → upstream's empty
        // `matcher_inputs`, which routes to `matches_matcher(matcher, None)`).
        switch req.eventName {
        case .userPromptSubmit, .stop:
            return true
        default:
            // Mirror `dispatcher::select_handlers_for_matcher_inputs`
            // (dispatcher.rs:54-61): when the matcher-input set is empty, test
            // against `None`; otherwise the handler matches if ANY input
            // matches. `matchInputs` is the canonical tool name plus any
            // compatibility aliases (e.g. apply_patch → ["Write", "Edit"]).
            let inputs = req.matchInputs
            if inputs.isEmpty {
                return Self.matchesMatcher(def.matcher, nil)
            }
            return inputs.contains { Self.matchesMatcher(def.matcher, $0) }
        }
    }

    /// Faithful port of upstream `events::common::matches_matcher`
    /// (hooks/src/events/common.rs:120-135). `input == nil` models the
    /// `matcher_input == None` case (UserPromptSubmit / Stop, where the
    /// matcher is ignored): None matcher always matches, a match-all matcher
    /// matches, and any concrete matcher (exact or regex) fails because there
    /// is no input to test against.
    static func matchesMatcher(_ matcher: String?, _ input: String?) -> Bool {
        guard let matcher else { return true }
        // `is_match_all_matcher`: empty or "*" matches everything. NOTE:
        // upstream does NOT trim — only the literal empty string and literal
        // "*" are match-all.
        if isMatchAllMatcher(matcher) { return true }
        // `is_exact_matcher`: alphanumeric / `_` / `|` only → split on `|` and
        // require an EXACT (not substring) equality with the input.
        if isExactMatcher(matcher) {
            guard let input else { return false }
            return matcher.split(separator: "|", omittingEmptySubsequences: false)
                .contains { $0 == Substring(input) }
        }
        // Otherwise treat as a regex matched against the input.
        guard let input else { return false }
        guard let re = try? NSRegularExpression(pattern: matcher) else { return false }
        let r = NSRange(input.startIndex..<input.endIndex, in: input)
        return re.firstMatch(in: input, range: r) != nil
    }

    static func isMatchAllMatcher(_ matcher: String) -> Bool {
        matcher.isEmpty || matcher == "*"
    }

    static func isExactMatcher(_ matcher: String) -> Bool {
        matcher.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "|")
        }
    }

    /// Paired `hook/started` + `hook/completed` summaries for one hook run,
    /// recorded by `fire` and drained by the SessionEngine for emission.
    public struct HookRunRecord: Sendable, Equatable {
        public let started: HookRunSummary
        public let completed: HookRunSummary
    }
    private var lastRunRecords: [HookRunRecord] = []
    /// Drain the run records produced by the most recent `fire(...)` so the
    /// caller can emit `hook/started` / `hook/completed` notifications.
    public func drainHookRunRecords() -> [HookRunRecord] {
        let r = lastRunRecords; lastRunRecords = []; return r
    }

    public func fire(_ event: HookEventName, _ req: HookRequest) async -> [HookOutcome] {
        var out: [HookOutcome] = []
        var records: [HookRunRecord] = []
        // Upstream HookRunSummary: started_at/completed_at are Unix SECONDS;
        // duration_ms is milliseconds. Scope is `turn` for all turn-scoped
        // events (every hook except SessionStart, which is thread-scoped).
        let scope = (event == .sessionStart) ? "thread" : "turn"

        // Upstream emits ALL `hook/started` events for the matched hook set
        // BEFORE running any hook (core/src/hook_runtime.rs: emit_hook_started_events
        // over preview_runs, then hooks.run(...), then emit_hook_completed_events).
        // We mirror that batched ordering: build the started summaries for every
        // matched hook first, then run each command, then build the completed
        // summaries. SessionEngine.emitHookRuns drains in the same two phases so
        // the wire order is started(A),started(B),...,completed(A),completed(B).
        struct Pending {
            let def: HookDefinition
            let order: Int
            let id: String
            let startedAtSec: Int
            let startedAtMs: Double
            let started: HookRunSummary
        }
        var pendings: [Pending] = []
        for def in hooks
        where def.eventName == event && matches(def, req) {
            // Upstream `ConfiguredHandler::run_id()` (hooks/src/engine/mod.rs:53-62):
            // `format!("{}:{}:{}", event_name_label(), display_order, source_path)`
            // where event_name_label() is the kebab wire form and display_order is
            // the STABLE global discovery index (NOT a per-fire counter). This id
            // is carried verbatim on every `hook/started` / `hook/completed`
            // notification and Stop continuation fragments key off it, so it must
            // match byte-for-byte.
            let order = def.displayOrder
            // For the three tool-scoped events upstream appends a run-id suffix
            // via `common::hook_run_for_tool_use` (hooks/src/events/common.rs:93-95):
            // PreToolUse/PostToolUse append `tool_use_id`, PermissionRequest
            // appends `run_id_suffix`. The suffix lands on BOTH the started
            // (preview) and completed summaries (pre_tool_use.rs:64-65,132-133;
            // permission_request.rs:77-79,141), so the id reads
            // `{event}:{display_order}:{source_path}:{suffix}`.
            var id = "\(def.eventName.wire):\(order):\(def.sourcePath)"
            if let suffix = req.hookRunIdSuffix {
                id += ":\(suffix)"
            }
            let startedAtSec = Int(Date().timeIntervalSince1970)
            let startedAtMs = Date().timeIntervalSince1970 * 1000
            let started = HookRunSummary(
                id: id, eventName: def.eventName.rawValue, scope: scope,
                sourcePath: def.sourcePath, source: def.source,
                displayOrder: order, status: "running",
                statusMessage: def.statusMessage, startedAt: startedAtSec)
            pendings.append(Pending(def: def, order: order, id: id,
                                    startedAtSec: startedAtSec,
                                    startedAtMs: startedAtMs, started: started))
        }
        for p in pendings {
            let outcome = await runCommand(p.def, req)
            out.append(outcome)
            let completedAtSec = Int(Date().timeIntervalSince1970)
            let durationMs = Int(max(0, Date().timeIntervalSince1970 * 1000 - p.startedAtMs))
            let (status, entries) = Self.summarize(outcome)
            // statusMessage is the CONFIGURED handler value (unchanged across
            // outcomes), threaded onto both summaries — never outcome-derived.
            let completed = HookRunSummary(
                id: p.id, eventName: p.def.eventName.rawValue, scope: scope,
                sourcePath: p.def.sourcePath, source: p.def.source,
                displayOrder: p.order, status: status,
                statusMessage: p.def.statusMessage,
                startedAt: p.startedAtSec, completedAt: completedAtSec,
                durationMs: durationMs, entries: entries)
            records.append(HookRunRecord(started: p.started, completed: completed))
        }
        lastRunRecords = records
        return out
    }

    /// Map a `HookOutcome` to a v2 `HookRunStatus` + ordered entries
    /// (`HookOutputEntry`): schema violation → `failed`+error; stop → `stopped`;
    /// block → `blocked`; otherwise `completed`.
    ///
    /// Entry ordering mirrors upstream's per-event parsers, which ALWAYS push
    /// the universal `systemMessage` (`Warning`) entry FIRST, before any
    /// event-specific stop/feedback/context/error entry (stop.rs:149-155,
    /// pre_tool_use.rs:208-213, user_prompt_submit.rs:154-160,
    /// session_start.rs:166-172). The `entries` array is ordered and
    /// wire-observable, so warning leads.
    ///
    /// A Stop hook that BLOCKS (decision:block with a non-empty reason, or
    /// exit-code 2 with stderr) records its continuation reason as a `feedback`
    /// entry (stop.rs:171-184, :201-211); the `stop` kind is reserved ONLY for
    /// the true `continue:false` stop_reason (stop.rs:160-166).
    ///
    /// NOTE: `statusMessage` is NOT derived here — upstream surfaces the
    /// CONFIGURED handler `status_message` on the summary unchanged
    /// (dispatcher.rs:79,132), so it is threaded in by the caller.
    static func summarize(_ o: HookOutcome) -> (String, [HookOutputEntry]) {
        var entries: [HookOutputEntry] = []
        // Universal warning (systemMessage) leads, matching upstream.
        if let m = o.systemMessage, !m.isEmpty {
            entries.append(HookOutputEntry(kind: "warning", text: m))
        }
        if let c = o.additionalContext, !c.isEmpty {
            entries.append(HookOutputEntry(kind: "context", text: c))
        }
        // The event-specific block reason surfaces as exactly ONE `feedback`
        // entry. For a Stop-block the reason is carried by `continuationPrompt`
        // (the trimmed value upstream pushes, stop.rs:181-184); for every other
        // blocking event it is carried by `reason`. They never both contribute
        // for the same run (continuationPrompt is only set for Stop, where it
        // equals the trimmed `reason`), so prefer continuationPrompt to avoid a
        // duplicate feedback entry.
        if !o.shouldStop {
            if let s = o.continuationPrompt, !s.isEmpty {
                entries.append(HookOutputEntry(kind: "feedback", text: s))
            } else if let r = o.reason, !r.isEmpty {
                entries.append(HookOutputEntry(kind: "feedback", text: r))
            }
        }
        // H-hooks F8 — PostToolUse exit-2 stderr surfaces as a dedicated
        // `feedback` entry (post_tool_use.rs:256-269), distinct from `context`.
        if let f = o.feedbackMessage, !f.isEmpty {
            entries.append(HookOutputEntry(kind: "feedback", text: f))
        }
        if let e = o.outputSchemaError, !e.isEmpty {
            entries.append(HookOutputEntry(kind: "error", text: e))
        }
        // Only a true continue:false termination reason is a `stop` entry.
        if o.shouldStop, let s = o.stopReason, !s.isEmpty {
            entries.append(HookOutputEntry(kind: "stop", text: s))
        }
        let status: String
        if o.outputSchemaError != nil {
            status = "failed"
        } else if o.shouldStop {
            status = "stopped"
        } else if o.decision == .block || o.shouldBlock {
            status = "blocked"
        } else {
            status = "completed"
        }
        return (status, entries)
    }

    public func aggregate(_ outcomes: [HookOutcome]) -> HookDecision {
        outcomes.contains { $0.decision == .block } ? .block : .allow
    }

    public func blockingReason(_ outcomes: [HookOutcome]) -> String? {
        guard let b = outcomes.first(where: { $0.decision == .block }) else { return nil }
        return b.reason ?? "blocked by hook"
    }

    /// P4.6 / H-29, H-40 — aggregate Stop-hook outcomes the way upstream
    /// `events/stop.rs::aggregate_results` does:
    ///   - `shouldStop` wins (any hook signals continue:false → terminate).
    ///   - Otherwise, any `shouldBlock` becomes an aggregate block whose
    ///     `continuationPrompt` is the join of all non-empty continuation
    ///     fragments (declaration order, joined by `\n\n`).
    public struct StopAggregate: Sendable, Equatable {
        public var shouldStop: Bool
        public var stopReason: String?
        public var shouldBlock: Bool
        public var continuationPrompt: String?
        public init(shouldStop: Bool = false, stopReason: String? = nil,
                    shouldBlock: Bool = false, continuationPrompt: String? = nil) {
            self.shouldStop = shouldStop
            self.stopReason = stopReason
            self.shouldBlock = shouldBlock
            self.continuationPrompt = continuationPrompt
        }
    }

    public func aggregateStop(_ outcomes: [HookOutcome]) -> StopAggregate {
        let shouldStop = outcomes.contains { $0.shouldStop }
        let stopReason = outcomes.first(where: { $0.shouldStop })?.stopReason
        let shouldBlock = !shouldStop && outcomes.contains { $0.shouldBlock }
        var prompt: String?
        if shouldBlock {
            let fragments = outcomes
                .filter { $0.shouldBlock }
                .compactMap { $0.continuationPrompt }
                .filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            if !fragments.isEmpty {
                prompt = fragments.joined(separator: "\n\n")
            }
        }
        return StopAggregate(shouldStop: shouldStop, stopReason: stopReason,
                             shouldBlock: shouldBlock,
                             continuationPrompt: prompt)
    }

    public struct AfterAgentPayload: Sendable, Equatable {
        public var threadId: String
        public var turnId: String
        public var cwd: String
        public var client: String?
        public var inputMessages: [String]
        public var lastAssistantMessage: String?

        public init(threadId: String, turnId: String, cwd: String,
                    client: String? = nil, inputMessages: [String],
                    lastAssistantMessage: String?) {
            self.threadId = threadId
            self.turnId = turnId
            self.cwd = cwd
            self.client = client
            self.inputMessages = inputMessages
            self.lastAssistantMessage = lastAssistantMessage
        }
    }

    public static func legacyNotifyJSON(_ payload: AfterAgentPayload) throws -> String {
        var object: [String: Any] = [
            "type": "agent-turn-complete",
            "thread-id": payload.threadId,
            "turn-id": payload.turnId,
            "cwd": payload.cwd,
            "input-messages": payload.inputMessages,
        ]
        if let client = payload.client { object["client"] = client }
        // Upstream `UserNotification::AgentTurnComplete` only marks `client`
        // with `skip_serializing_if=Option::is_none` (hooks/src/legacy_notify.rs:14-25);
        // `last_assistant_message` is a plain `Option<String>` with NO skip, so
        // when None it serializes as `"last-assistant-message": null` — the key
        // is always present.
        object["last-assistant-message"] = payload.lastAssistantMessage as Any? ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Codex legacy `notify = [...]`: after a successful agent turn, append a
    /// historical `agent-turn-complete` JSON payload as the final argv token
    /// and spawn without blocking turn completion. Spawn failures are reported
    /// as failed-continue outcomes by returning `false`; they never abort the
    /// completed user turn.
    public func fireAfterAgent(_ payload: AfterAgentPayload) async -> Bool {
        guard let argv = legacyNotifyArgv, !argv.isEmpty, !argv[0].isEmpty else {
            return true
        }
        let json: String
        do {
            json = try Self.legacyNotifyJSON(payload)
        } catch {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst()) + [json]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    // MARK: command runner (ProcBox + dedicated blocking thread + timeout)

    private struct RunResult: Sendable {
        var stdout: String = ""
        var stderr: String = ""
        var exitCode: Int32 = 0
        var timedOut: Bool = false
    }

    private final class ProcBox: @unchecked Sendable {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
    }

    private final class Resumer: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cont: CheckedContinuation<RunResult, Never>?
        func bind(_ c: CheckedContinuation<RunResult, Never>) {
            lock.lock(); cont = c; lock.unlock()
        }
        func resume(_ r: RunResult) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: r)
        }
    }

    /// Parse the modern `hookSpecificOutput` structured-output protocol. Returns
    /// the per-event typed payload plus the *effective* `additionalContext`
    /// (falling back to the flat legacy `additionalContext` / `additional_context`
    /// keys when no structured object is present). Faithful to upstream
    /// `codex_hooks::engine::output_parser` event-dispatch logic.
    private static func parseHookSpecificOutput(_ obj: [String: Any],
                                                event: HookEventName)
        -> (HookSpecificOutput?, String?, String?) {
        let flatAddCtx = (obj["additionalContext"] as? String)
            ?? (obj["additional_context"] as? String)
        guard let hso = obj["hookSpecificOutput"] as? [String: Any] else {
            return (nil, flatAddCtx, nil)
        }
        var out = HookSpecificOutput()
        var schemaError: String?
        // PreToolUse: { permissionDecision, permissionDecisionReason, updatedInput, additionalContext }
        // PermissionRequest: { decision: { behavior: "allow"|"deny", message? } }
        // PostToolUse / SessionStart / UserPromptSubmit: { additionalContext }
        switch event {
        case .preToolUse:
            if let pd = hso["permissionDecision"] as? String,
               let parsed = HookSpecificOutput.PermissionDecision(
                rawValue: pd.lowercased()) {
                out.permissionDecision = parsed
            }
            out.permissionDecisionReason =
                hso["permissionDecisionReason"] as? String
            // Track raw presence of `updatedInput` (upstream keys on
            // `updated_input.is_some()`, i.e. the field being present, not on
            // whether it re-serialized).
            let updatedInputPresent = hso["updatedInput"] != nil
                && !(hso["updatedInput"] is NSNull)
            if let upd = hso["updatedInput"] as? [String: Any],
               let bytes = try? JSONSerialization.data(withJSONObject: upd,
                                                       options: [.sortedKeys]) {
                out.updatedInputJSON = String(decoding: bytes, as: UTF8.self)
            }
            out.additionalContext = (hso["additionalContext"] as? String)
                ?? (hso["additional_context"] as? String)
            // Faithful port of upstream
            // `unsupported_pre_tool_use_hook_specific_output`
            // (output_parser.rs:388-432). The checks are mutually exclusive and
            // ordered exactly as upstream:
            //   1. updatedInput present && permissionDecision != allow →
            //      "PreToolUse hook returned updatedInput without
            //      permissionDecision:allow" (F4).
            //   2. permissionDecision == allow && updatedInput absent →
            //      "PreToolUse hook returned unsupported permissionDecision:allow".
            //   3. permissionDecision == ask →
            //      "PreToolUse hook returned unsupported permissionDecision:ask" (F3).
            //   4. permissionDecision == deny && no non-empty reason →
            //      "PreToolUse hook returned permissionDecision:deny without a
            //      non-empty permissionDecisionReason".
            //   5. permissionDecision == none && permissionDecisionReason
            //      present → "PreToolUse hook returned permissionDecisionReason
            //      without permissionDecision" (F5).
            // Upstream marks the run Failed (HookRunStatus::Failed) and drops
            // updated_input/block_reason when invalid_reason fires; we mirror
            // via `outputSchemaError` and clear `updatedInputJSON`.
            let denyReasonEmpty = (out.permissionDecisionReason ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if updatedInputPresent, out.permissionDecision != .allow {
                schemaError = "PreToolUse hook returned updatedInput without permissionDecision:allow"
            } else {
                switch out.permissionDecision {
                case .allow where !updatedInputPresent:
                    schemaError = "PreToolUse hook returned unsupported permissionDecision:allow"
                case .ask:
                    schemaError = "PreToolUse hook returned unsupported permissionDecision:ask"
                case .deny where denyReasonEmpty:
                    schemaError = "PreToolUse hook returned permissionDecision:deny" +
                        " without a non-empty permissionDecisionReason"
                case .none where out.permissionDecisionReason != nil:
                    schemaError = "PreToolUse hook returned permissionDecisionReason without permissionDecision"
                default:
                    break
                }
            }
            if let msg = schemaError {
                hookLog.warn(msg)
                // Upstream drops updated_input on any invalid_reason.
                out.updatedInputJSON = nil
            }
        case .permissionRequest:
            // Upstream nests behavior under `decision` (not `permissionDecision`).
            if let decisionObj = hso["decision"] as? [String: Any] {
                if let behavior = decisionObj["behavior"] as? String,
                   let parsed = HookSpecificOutput.PermissionDecision(
                    rawValue: behavior.lowercased()) {
                    out.permissionDecision = parsed
                }
                out.permissionDenyMessage = decisionObj["message"] as? String
                // H-hooks F6: faithful port of upstream
                // `unsupported_permission_request_hook_specific_output`
                // (output_parser.rs:351-364). The reserved decision fields are
                // checked in order; the first present one marks the run Failed
                // and the decision is dropped (parse_permission_request drops
                // `decision` when invalid_reason is Some).
                if decisionObj["updatedInput"] != nil
                    && !(decisionObj["updatedInput"] is NSNull) {
                    schemaError = "PermissionRequest hook returned unsupported updatedInput"
                } else if decisionObj["updatedPermissions"] != nil
                    && !(decisionObj["updatedPermissions"] is NSNull) {
                    schemaError = "PermissionRequest hook returned unsupported updatedPermissions"
                } else if (decisionObj["interrupt"] as? Bool) == true {
                    schemaError = "PermissionRequest hook returned unsupported interrupt:true"
                }
                if schemaError != nil {
                    // Decision dropped on invalid_reason.
                    out.permissionDecision = nil
                    out.permissionDenyMessage = nil
                }
            }
        case .postToolUse, .sessionStart, .userPromptSubmit:
            out.additionalContext = (hso["additionalContext"] as? String)
                ?? (hso["additional_context"] as? String)
        case .preCompact, .postCompact, .stop, .subagentStart, .subagentStop:
            // Upstream wire types intentionally have no event-specific output
            // for these. We still allow callers to read `additionalContext`
            // if a hook author sends one (forward-compat / no-op today).
            out.additionalContext = (hso["additionalContext"] as? String)
                ?? (hso["additional_context"] as? String)
        }
        // Prefer structured additionalContext when present so the
        // SessionEngine sees a single value regardless of which protocol form
        // the hook used.
        let effective = out.additionalContext ?? flatAddCtx
        return (out, effective, schemaError)
    }

    private func runCommand(_ def: HookDefinition, _ req: HookRequest) async -> HookOutcome {
        let jsonData: Data = (try? JSONSerialization.data(
            withJSONObject: req.jsonObject(), options: [.sortedKeys]))
            ?? Data("{}".utf8)

        let box = ProcBox()
        box.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        box.process.arguments = ["/bin/sh", "-lc", def.command]
        box.process.standardInput = box.stdin
        box.process.standardOutput = box.stdout
        box.process.standardError = box.stderr
        // Upstream runs every hook with `command.current_dir(cwd)`
        // (hooks/src/engine/command_runner.rs:34-39) where cwd is the
        // turn/session working directory (pre_tool_use.rs:107
        // `request.cwd.as_path()`), so relative paths, `pwd`, and `$(git ...)`
        // resolve against the session cwd rather than the daemon's. Guard for
        // an empty/nonexistent path: when unset or missing we leave the
        // process to inherit the parent cwd (Process rejects a missing dir).
        if !req.cwd.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: req.cwd, isDirectory: &isDir),
               isDir.boolValue {
                box.process.currentDirectoryURL = URL(fileURLWithPath: req.cwd, isDirectory: true)
            }
        }

        // Upstream clamps only the LOWER bound:
        // `timeout_sec.unwrap_or(600).max(1)` (hooks/src/engine/discovery.rs:457)
        // then `Duration::from_secs(handler.timeout_sec)`
        // (command_runner.rs:71) — a configured timeout above 600 is honored
        // verbatim. Match that: lower-bound 1, no upper cap.
        let timeoutSecs = max(def.timeoutSec, 1)
        let reaper = self.reaper
        let resumer = Resumer()

        let result: RunResult = await withCheckedContinuation { cont in
            resumer.bind(cont)

            let timeoutTask = Task<Void, Never>.detached {
                try? await Task.sleep(nanoseconds: timeoutSecs * 1_000_000_000)
                if Task.isCancelled { return }
                let pid = box.process.processIdentifier
                if pid > 0 { reaper(pid) }
                if box.process.isRunning { box.process.terminate() }
                resumer.resume(RunResult(stdout: "", stderr: "",
                                         exitCode: -1, timedOut: true))
            }

            Thread.detachNewThread {
                var rr = RunResult()
                do {
                    try box.process.run()
                } catch {
                    rr.stderr = "spawn failed: \(error)"
                    rr.exitCode = 127
                    timeoutTask.cancel()
                    resumer.resume(rr)
                    return
                }
                var toWrite = jsonData
                toWrite.append(0x0A)
                let win = box.stdin.fileHandleForWriting
                try? win.write(contentsOf: toWrite)
                try? win.close()

                let maxBytes = 64 * 1024
                let outData = (try? box.stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? box.stderr.fileHandleForReading.readToEnd()) ?? Data()
                box.process.waitUntilExit()
                rr.exitCode = box.process.terminationStatus

                let boundedOut = outData.count > maxBytes
                    ? Data(outData.prefix(maxBytes)) : outData
                let boundedErr = errData.count > maxBytes
                    ? Data(errData.prefix(maxBytes)) : errData
                rr.stdout = String(decoding: boundedOut, as: UTF8.self)
                rr.stderr = String(decoding: boundedErr, as: UTF8.self)

                timeoutTask.cancel()
                resumer.resume(rr)
            }
        }

        if result.timedOut {
            return HookOutcome(decision: .allow, reason: "hook timed out", raw: "")
        }

        let raw = String(result.stdout.prefix(64 * 1024))
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{"),
           let d = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let reason = obj["reason"] as? String
            let trimmedReason = (reason ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasDecisionBlock: Bool = {
                if let dec = obj["decision"] as? String {
                    return dec.lowercased() == "block"
                }
                return false
            }()
            // P4.6 / H-29: Stop-hook semantic. Upstream's `events/stop.rs`
            // treats `continue: false` as "terminate the session" and
            // `decision: "block"` (with a non-empty reason) as "inject the
            // reason as a continuation prompt and re-enter sampling". The
            // legacy collapse to `.block` is preserved for the aggregate /
            // blockingReason API surface, but the new dedicated fields
            // (`shouldStop`, `shouldBlock`, `continuationPrompt`) carry the
            // full upstream signal for the SessionEngine to act on.
            var decision: HookDecision = .allow
            var shouldStop = false
            var stopReason: String?
            var shouldBlock = false
            var continuationPrompt: String?
            // `continue: false` is upstream's *universal* output field, and each
            // event interprets it differently:
            //   - Stop / PreCompact / PostCompact / SessionStart: terminator —
            //     sets `should_stop` (events/stop.rs, compact.rs:352-355,
            //     session_start.rs:180). `decision = .block` is also set for the
            //     compact events so the SessionEngine's aggregate()/blockingReason
            //     abort path keeps working.
            //   - PreToolUse / PermissionRequest: UNSUPPORTED — upstream's
            //     `unsupported_*_universal` (output_parser.rs:319-341) marks the
            //     run Failed and does NOT block or stop.
            //   - PostToolUse / UserPromptSubmit: ignored entirely (no error, no
            //     stop, no block) — their parsers don't inspect continue.
            var blockReasonGate: String?
            if let cont = obj["continue"] as? Bool, cont == false {
                switch req.eventName {
                case .stop, .preCompact, .postCompact, .sessionStart,
                     .subagentStart, .subagentStop:
                    shouldStop = true
                    stopReason = (obj["stopReason"] as? String)
                        ?? (obj["stop_reason"] as? String)
                    if req.eventName == .preCompact || req.eventName == .postCompact {
                        // Compaction abort flows through the legacy
                        // aggregate()/blockingReason API in firePreCompactHook.
                        decision = .block
                    }
                case .preToolUse, .permissionRequest:
                    blockReasonGate = blockReasonGate
                        ?? "\(req.eventName.pascalCase) hook returned unsupported continue:false"
                case .postToolUse:
                    // H-hooks F1: PostToolUse `continue:false` terminates the
                    // run. Upstream (events/post_tool_use.rs Some(0) arm) sets
                    // status=Stopped, should_stop=true, stop_reason from the
                    // universal field, and ALWAYS pushes a `Stop` entry whose
                    // text falls back to "PostToolUse hook stopped execution"
                    // when stop_reason is absent. continue:false is checked
                    // BEFORE invalid_reason/invalid_block_reason, so it wins
                    // over the suppressOutput / reason-without-decision gates.
                    shouldStop = true
                    stopReason = (obj["stopReason"] as? String)
                        ?? (obj["stop_reason"] as? String)
                        ?? "PostToolUse hook stopped execution"
                case .userPromptSubmit:
                    // H-hooks F2: UserPromptSubmit `continue:false` aborts the
                    // prompt. Upstream (events/user_prompt_submit.rs Some(0)
                    // arm) sets status=Stopped, should_stop=true, stop_reason
                    // from the universal field, and pushes a `Stop` entry ONLY
                    // when stop_reason is present (no fallback text, unlike
                    // PostToolUse). continue:false is checked before
                    // invalid_block_reason, so it wins.
                    shouldStop = true
                    stopReason = (obj["stopReason"] as? String)
                        ?? (obj["stop_reason"] as? String)
                }
            }
            // Universal `stopReason` / `suppressOutput` are unsupported on the
            // tool-scoped events and mark the run Failed
            // (output_parser.rs:319-345). Precedence within
            // `unsupported_*_universal` is continue:false → stopReason →
            // suppressOutput (the `else if` ladder), so these only set the gate
            // when continue:false didn't already. PreToolUse / PermissionRequest
            // flag BOTH stopReason and suppressOutput; PostToolUse flags only
            // suppressOutput (no stopReason arm). Other events accept these
            // fields and are unaffected.
            // Upstream `stop_reason: Option<String>` — JSON `null` is None, so a
            // literal `null` value is NOT a present stopReason.
            let universalStopReasonPresent =
                (obj["stopReason"] is String) || (obj["stop_reason"] is String)
            let suppressOutputTrue: Bool = {
                if let b = obj["suppressOutput"] as? Bool { return b }
                if let b = obj["suppress_output"] as? Bool { return b }
                return false
            }()
            switch req.eventName {
            case .preToolUse, .permissionRequest:
                if universalStopReasonPresent {
                    blockReasonGate = blockReasonGate
                        ?? "\(req.eventName.pascalCase) hook returned unsupported stopReason"
                } else if suppressOutputTrue {
                    blockReasonGate = blockReasonGate
                        ?? "\(req.eventName.pascalCase) hook returned unsupported suppressOutput"
                }
            case .postToolUse:
                // continue:false (shouldStop) wins over the suppressOutput
                // gate upstream (Stopped is set before invalid_reason).
                if suppressOutputTrue, !shouldStop {
                    blockReasonGate = blockReasonGate
                        ?? "PostToolUse hook returned unsupported suppressOutput"
                }
            case .preCompact, .postCompact, .sessionStart,
                 .userPromptSubmit, .stop, .subagentStart, .subagentStop:
                break
            }
            if let blk = obj["block"] as? Bool, blk == true { decision = .block }
            // `decision: "block"` handling. Upstream requires a non-empty reason
            // for UserPromptSubmit, PostToolUse, and Stop; an empty/missing
            // reason marks the run Failed and suppresses the block
            // (output_parser.rs:197-202, 243-251; events/stop.rs). For other
            // events (e.g. PreToolUse legacy decision:block), the reason is not
            // gated here.
            if hasDecisionBlock {
                switch req.eventName {
                case .stop:
                    // `shouldStop` (continue:false) wins over `shouldBlock`.
                    if !shouldStop {
                        if !trimmedReason.isEmpty {
                            decision = .block
                            shouldBlock = true
                            continuationPrompt = trimmedReason
                        } else {
                            blockReasonGate = blockReasonGate
                                ?? "Stop hook returned decision:block without a non-empty reason"
                        }
                    }
                case .userPromptSubmit, .postToolUse, .preToolUse:
                    // Upstream `unsupported_pre_tool_use_legacy_decision`
                    // (output_parser.rs:434-457) and the PostToolUse/
                    // UserPromptSubmit parsers all require a non-empty trimmed
                    // reason for a legacy `decision:block`; an empty/missing
                    // reason yields `block_reason = None` and an `invalid_reason`
                    // ("<Event> hook returned decision:block without a non-empty
                    // reason"), so the hook is marked Failed and does NOT block.
                    if !trimmedReason.isEmpty {
                        decision = .block
                    } else {
                        blockReasonGate = blockReasonGate
                            ?? "\(req.eventName.pascalCase) hook returned decision:block without a non-empty reason"
                    }
                default:
                    decision = .block
                }
            }
            // Upstream `unsupported_pre_tool_use_legacy_decision`
            // (output_parser.rs:434-457) flags two more PreToolUse legacy-decision
            // cases as Failed:
            //   - `decision:"approve"` → "PreToolUse hook returned unsupported
            //     decision:approve"
            //   - no `decision` but a top-level `reason` present → "PreToolUse hook
            //     returned reason without decision"
            // (`decision:"block"` is handled above.) These checks only run when
            // NOT using the hook-specific decision path
            // (`use_hook_specific_decision`, output_parser.rs:112-123): a
            // `hookSpecificOutput` carrying permissionDecision /
            // permissionDecisionReason / updatedInput takes the structured path
            // instead.
            if req.eventName == .preToolUse {
                let usesHookSpecificDecision: Bool = {
                    guard let hsoRaw = obj["hookSpecificOutput"] as? [String: Any] else {
                        return false
                    }
                    return hsoRaw["permissionDecision"] != nil
                        || hsoRaw["permissionDecisionReason"] != nil
                        || hsoRaw["updatedInput"] != nil
                }()
                if !usesHookSpecificDecision {
                    let decisionStr = (obj["decision"] as? String)?.lowercased()
                    // Upstream `decision: Option<...>` treats both an absent key
                    // and JSON `null` as None.
                    let decisionIsNone =
                        obj["decision"] == nil || obj["decision"] is NSNull
                    if decisionStr == "approve" {
                        blockReasonGate = blockReasonGate
                            ?? "PreToolUse hook returned unsupported decision:approve"
                    } else if decisionIsNone, obj["reason"] != nil {
                        // `reason` present (any value, including empty) but no
                        // `decision` → reason-without-decision. Upstream keys on
                        // `reason.is_some()` regardless of trimmed content.
                        blockReasonGate = blockReasonGate
                            ?? "PreToolUse hook returned reason without decision"
                    }
                }
            }
            // H-hooks F7: PostToolUse reason-without-decision. Upstream
            // (output_parser.rs:203-204) sets invalid_block_reason =
            // "PostToolUse hook returned reason without decision" when
            // `!should_block && universal.continue_processing && reason.is_some()`.
            // `should_block` is the legacy decision:block (only honored with a
            // non-empty reason); `continue_processing` means continue:false was
            // not set (continue:false / shouldStop wins over this gate, checked
            // first upstream). Keyed on `reason.is_some()` regardless of trimmed
            // content (the empty-reason+decision:block case is already handled
            // by the decision:block-without-reason gate above).
            if req.eventName == .postToolUse, !shouldStop, !hasDecisionBlock,
               obj["reason"] != nil {
                blockReasonGate = blockReasonGate
                    ?? "PostToolUse hook returned reason without decision"
            }
            let sysMsg = (obj["systemMessage"] as? String)
                ?? (obj["system_message"] as? String)
            // Parse `hookSpecificOutput` (modern protocol). Fall back to flat
            // legacy `additionalContext` if no structured form is present.
            let (hso, flatAddCtx, hsoSchemaError) = Self.parseHookSpecificOutput(obj, event: req.eventName)
            // Universal-field / block-reason gate (continue:false on non-Stop,
            // decision:block-without-reason on UserPromptSubmit/PostToolUse/Stop)
            // surfaces as a schema error so summarize() reports `failed`. Keep an
            // already-present hookSpecificOutput schema error (it is more
            // specific) if both fire.
            let schemaError = hsoSchemaError ?? blockReasonGate
            // PermissionRequest hook's deny decision implies block at the
            // outcome level so existing aggregate/blockingReason paths keep
            // working without callers having to peek into hookSpecificOutput.
            // (PreToolUse `deny` does NOT auto-block here — upstream maps it
            // through a separate PreToolUseHookResult; SessionEngine will
            // honor it via hookSpecificOutput.)
            if req.eventName == .permissionRequest,
               hso?.permissionDecision == .deny {
                decision = .block
            }
            return HookOutcome(decision: decision, reason: reason,
                               systemMessage: sysMsg,
                               additionalContext: flatAddCtx,
                               hookSpecificOutput: hso,
                               shouldStop: shouldStop,
                               stopReason: stopReason,
                               shouldBlock: shouldBlock,
                               continuationPrompt: continuationPrompt,
                               outputSchemaError: schemaError,
                               raw: raw)
        }

        // Invalid-JSON-output parity. Upstream every event parser, on exit 0
        // with `looks_like_json(stdout)` (starts with `{` or `[`) but a parse
        // failure, marks the run `HookRunStatus::Failed` with a per-event
        // "hook returned invalid <event> JSON output" Error entry (e.g.
        // post_tool_use.rs:248-254, session_start.rs:193-199). The JSON-success
        // path above returns; reaching here with a JSON-looking stdout at exit
        // 0 means the parse failed (or the stdout is `[`-prefixed, which never
        // decodes to a hook object) — surface it as a failed run. No block.
        if result.exitCode == 0,
           trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return HookOutcome(decision: .allow, reason: nil,
                               outputSchemaError: req.eventName.invalidJSONMessage,
                               raw: raw)
        }

        if result.exitCode == 2 {
            // Per-event exit-code-2 semantics, ported faithfully from each
            // `hooks/src/events/*.rs` parser. The stderr message (trimmed and
            // required non-empty) is the user-facing signal; an empty stderr is
            // a `HookRunStatus::Failed` with a per-event message surfaced via
            // `outputSchemaError`. Critically, exit-2 means different things per
            // event: PreToolUse/PermissionRequest BLOCK, PostToolUse FEEDBACK
            // (no block — the tool already ran), Stop CONTINUATION, and
            // UserPromptSubmit STOP. SessionStart and PreCompact/PostCompact
            // have NO exit-2 arm at all — they fall through to the generic
            // nonzero-exit Failed path.
            let stderrTrimmed = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch req.eventName {
            case .preToolUse:
                // pre_tool_use.rs:248-264 — Blocked with the stderr feedback.
                if !stderrTrimmed.isEmpty {
                    return HookOutcome(decision: .block, reason: stderrTrimmed,
                                       shouldBlock: true, raw: raw)
                }
                return HookOutcome(decision: .allow, reason: nil,
                    outputSchemaError:
                        "PreToolUse hook exited with code 2 but did not write a blocking reason to stderr",
                    raw: raw)
            case .permissionRequest:
                // permission_request.rs:243-258 — Blocked → Deny{message}.
                // Upstream sets `decision = Deny { message }`; the consumer
                // (`firePermissionRequestHook`) reads the structured
                // permissionDecision, so we MUST populate `hookSpecificOutput`
                // here (not just the legacy `decision:.block`), otherwise the
                // deny is silently dropped and the tool is permitted
                // (fail-OPEN security bug). Carry both the structured
                // permissionDecision=.deny + permissionDenyMessage AND the
                // legacy decision:.block for belt-and-suspenders parity.
                if !stderrTrimmed.isEmpty {
                    return HookOutcome(decision: .block, reason: stderrTrimmed,
                                       hookSpecificOutput: HookSpecificOutput(
                                           permissionDecision: .deny,
                                           permissionDenyMessage: stderrTrimmed),
                                       raw: raw)
                }
                return HookOutcome(decision: .allow, reason: nil,
                    outputSchemaError:
                        "PermissionRequest hook exited with code 2 but did not write a denial reason to stderr",
                    raw: raw)
            case .postToolUse:
                // post_tool_use.rs:256-269 — stderr is model FEEDBACK, NOT a
                // block (the tool has already run) and NOT additional context.
                // Upstream pushes a `HookOutputEntryKind::Feedback` entry and a
                // `feedback_messages_for_model` message (which replaces the tool
                // output text); it does NOT call append_additional_context (which
                // would be a `Context` entry). H-hooks F8: route via
                // `feedbackMessage` so summarize() emits a `feedback` entry while
                // status stays `completed`.
                if !stderrTrimmed.isEmpty {
                    return HookOutcome(decision: .allow, reason: nil,
                                       feedbackMessage: stderrTrimmed,
                                       raw: raw)
                }
                return HookOutcome(decision: .allow, reason: nil,
                    outputSchemaError:
                        "PostToolUse hook exited with code 2 but did not write feedback to stderr",
                    raw: raw)
            case .stop:
                // stop.rs:203-228 — stderr becomes the continuation prompt
                // (re-enter sampling); empty stderr is a Failed run, no block.
                if !stderrTrimmed.isEmpty {
                    return HookOutcome(decision: .block, reason: stderrTrimmed,
                                       shouldBlock: true,
                                       continuationPrompt: stderrTrimmed,
                                       raw: raw)
                }
                return HookOutcome(decision: .allow, reason: nil,
                    outputSchemaError:
                        "Stop hook exited with code 2 but did not write a continuation prompt to stderr",
                    raw: raw)
            case .userPromptSubmit:
                // user_prompt_submit.rs:212-227 — stderr aborts the prompt
                // (should_stop with the stderr as the stop reason).
                if !stderrTrimmed.isEmpty {
                    return HookOutcome(decision: .block, reason: stderrTrimmed,
                                       shouldStop: true,
                                       stopReason: stderrTrimmed,
                                       raw: raw)
                }
                return HookOutcome(decision: .allow, reason: nil,
                    outputSchemaError:
                        "UserPromptSubmit hook exited with code 2 but did not write a blocking reason to stderr",
                    raw: raw)
            case .sessionStart, .subagentStart, .subagentStop:
                // session_start.rs:208-214 — NO exit-2 arm: exit 2 is just a
                // generic nonzero exit → Failed, no block, no context. The
                // subagent events share this: the one-shot subagent runner can
                // honor neither a Stop-style continuation nor a block.
                return HookOutcome(decision: .allow, reason: nil,
                    outputSchemaError: "hook exited with code 2", raw: raw)
            case .preCompact, .postCompact:
                // compact.rs:275-282 — NO exit-2 arm: Failed with stderr (or
                // the generic message), and compaction is NOT aborted (block is
                // reserved for the stdout `continue:false` path).
                return HookOutcome(decision: .allow, reason: nil,
                    outputSchemaError: stderrTrimmed.isEmpty
                        ? "hook exited with code 2" : stderrTrimmed,
                    raw: raw)
            }
        }

        // Generic nonzero-exit (other than the per-event exit-2 cases above):
        // every upstream parser maps an unhandled nonzero exit code to a
        // `HookRunStatus::Failed` with `format!("hook exited with code {N}")`
        // (or, for PreCompact/PostCompact, the trimmed stderr if present). No
        // block/stop/context — surface as a failed run via outputSchemaError.
        if result.exitCode != 0 {
            let stderrTrimmed = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let failMsg: String
            if (req.eventName == .preCompact || req.eventName == .postCompact),
               !stderrTrimmed.isEmpty {
                failMsg = stderrTrimmed
            } else {
                failMsg = "hook exited with code \(result.exitCode)"
            }
            return HookOutcome(decision: .allow, reason: nil,
                               outputSchemaError: failMsg, raw: raw)
        }

        // Bare-text stdout convenience path. Upstream's UserPromptSubmit and
        // SessionStart parsers (events/user_prompt_submit.rs:197-210,
        // events/session_start.rs:199-205): when exit code is 0, stdout is
        // non-empty, and it does NOT look like JSON (`looks_like_json` =
        // starts with `{` or `[`), the trimmed stdout is injected into the
        // model turn as additionalContext. Note `[`-prefixed stdout that
        // failed to parse is upstream-Failed-invalid-JSON, NOT context — so we
        // gate on the leading char, mirroring `looks_like_json`.
        if result.exitCode == 0, !trimmed.isEmpty,
           !trimmed.hasPrefix("{"), !trimmed.hasPrefix("["),
           (req.eventName == .userPromptSubmit || req.eventName == .sessionStart) {
            return HookOutcome(decision: .allow, reason: nil,
                               additionalContext: trimmed, raw: raw)
        }

        return HookOutcome(decision: .allow, reason: nil, raw: raw)
    }
}
