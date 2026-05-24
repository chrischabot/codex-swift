import Foundation
import Tools
import InfraPrimitives
import Observability
import Config
import WireProtocol

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

    public init(eventName: HookEventName, matcher: String? = nil,
                command: String, timeoutSec: UInt64 = HookDefinition.defaultTimeoutSec) {
        self.eventName = eventName
        self.matcher = matcher
        self.command = command
        self.timeoutSec = timeoutSec
    }

    /// Default hook timeout in seconds. Matches upstream codex-rs
    /// (`engine/discovery.rs::timeout_sec.unwrap_or(600)`). Hardening
    /// note: clamped to `[1, 600]` inside `runCommand()` so a misconfigured
    /// hook can never block a turn indefinitely.
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
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(eventName.wire, forKey: DynamicKey("event"))
        if let matcher { try c.encode(matcher, forKey: DynamicKey("matcher")) }
        try c.encode(command, forKey: DynamicKey("command"))
        try c.encode(timeoutSec, forKey: DynamicKey("timeout"))
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
    public var raw: String

    public init(decision: HookDecision, reason: String? = nil,
                systemMessage: String? = nil, additionalContext: String? = nil,
                hookSpecificOutput: HookSpecificOutput? = nil,
                shouldStop: Bool = false, stopReason: String? = nil,
                shouldBlock: Bool = false, continuationPrompt: String? = nil,
                outputSchemaError: String? = nil,
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
    public var extra: [String: String]

    public init(eventName: HookEventName, sessionId: String, cwd: String,
                toolName: String? = nil, toolArgumentsJSON: String? = nil,
                toolOutput: String? = nil, prompt: String? = nil,
                turnId: String? = nil, model: String? = nil,
                permissionMode: String? = nil, transcriptPath: String? = nil,
                source: String? = nil, stopHookActive: Bool? = nil,
                lastAssistantMessage: String? = nil,
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
        self.extra = extra
    }

    /// codex treats the matcher as meaningful only for pre/post-tool-use
    /// (matched against the tool name); empty otherwise.
    public var matchString: String { toolName ?? "" }

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
        o["permission_mode"] = permissionMode ?? "default"
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
        // PostToolUse: upstream key is `tool_response` (P4.6 / H-28).
        if eventName == .postToolUse, let toolOutput {
            if let d = toolOutput.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) {
                o["tool_response"] = parsed
            } else {
                o["tool_response"] = toolOutput
            }
            // Upstream also carries `tool_use_id`. We don't track per-tool
            // call ids on the request struct yet; reuse `tool_name`-prefixed
            // placeholder for forward compat. Hooks that don't read this
            // field are unaffected.
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
        if eventName == .stop {
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
        func parse(_ data: Data, path: String) -> [HookDefinition] {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return []
            }
            let rawHooks = value["hooks"]?.arrayValue ?? value.arrayValue ?? []
            let dec = JSONDecoder()
            var out: [HookDefinition] = []
            for (index, raw) in rawHooks.enumerated() {
                guard let object = raw.objectValue,
                      let encoded = try? JSONEncoder().encode(raw),
                      let def = try? dec.decode(HookDefinition.self, from: encoded) else {
                    continue
                }
                let event = object["event"]?.stringValue
                    ?? object["eventName"]?.stringValue
                    ?? object["event_name"]?.stringValue
                    ?? def.eventName.rawValue
                let eventName = normalizedHookEventName(event) ?? def.eventName.configKey
                let key = "\(path):\(eventName):\(index):0"
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
        func read(_ path: String) -> [HookDefinition] {
            guard let d = FileManager.default.contents(atPath: path) else { return [] }
            return parse(d, path: path)
        }
        var defs: [HookDefinition] = []
        let homeFile = (codexHome as NSString)
            .appendingPathComponent("hooks.json")
        let cwdFile = ((cwd as NSString)
            .appendingPathComponent(".codex") as NSString)
            .appendingPathComponent("hooks.json")
        defs.append(contentsOf: read(homeFile))
        defs.append(contentsOf: read(cwdFile))
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
        // command_windows + statusMessage are always None in our config
        // shape today; omit them to match upstream's TOML-dropped Nones.

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
        guard let m = def.matcher, !m.isEmpty else { return true }
        let s = req.matchString
        if let re = try? NSRegularExpression(pattern: m) {
            let r = NSRange(s.startIndex..<s.endIndex, in: s)
            return re.firstMatch(in: s, range: r) != nil
        }
        return s.contains(m)
    }

    public func fire(_ event: HookEventName, _ req: HookRequest) async -> [HookOutcome] {
        var out: [HookOutcome] = []
        for def in hooks
        where def.eventName == event && matches(def, req) {
            out.append(await runCommand(def, req))
        }
        return out
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
        if let last = payload.lastAssistantMessage {
            object["last-assistant-message"] = last
        }
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
            if let upd = hso["updatedInput"] as? [String: Any],
               let bytes = try? JSONSerialization.data(withJSONObject: upd,
                                                       options: [.sortedKeys]) {
                out.updatedInputJSON = String(decoding: bytes, as: UTF8.self)
            }
            out.additionalContext = (hso["additionalContext"] as? String)
                ?? (hso["additional_context"] as? String)
            // P4.5 / F3: warn when permissionDecision:allow lacks updatedInput.
            // Upstream `unsupported_pre_tool_use_hook_specific_output` flags
            // this as invalid ("PreToolUse hook returned unsupported
            // permissionDecision:allow"). String is kept byte-for-byte
            // identical to upstream `output_parser.rs` so log scrapers and
            // shared tooling can match either implementation.
            //
            // Divergence note (deliberate): upstream marks the hook
            // `HookRunStatus::Failed` and emits a `HookOutputEntryKind::Error`
            // alongside this message (see `events/pre_tool_use.rs:214-219`).
            // We surface the same signal at the outcome level via
            // `outputSchemaError` (see below) so callers that want the
            // "this output violated the schema" bit can act on it; the log
            // itself stays at warn because there is no per-hook run-status
            // surface in Swift today and downgrading to "this turn failed"
            // would over-escalate compared to upstream (the hook still
            // returns — just with its decision ignored).
            if out.permissionDecision == .allow, out.updatedInputJSON == nil {
                let msg = "PreToolUse hook returned unsupported permissionDecision:allow"
                hookLog.warn(msg)
                schemaError = msg
            }
            // P4.5 / F4: warn when permissionDecision:deny lacks a non-empty
            // permissionDecisionReason. Upstream `invalid_pre_tool_use_reason_message`
            // flags this as invalid (and likewise marks `HookRunStatus::Failed`
            // — see divergence note above; we mirror via `outputSchemaError`).
            if out.permissionDecision == .deny,
               (out.permissionDecisionReason ?? "")
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let msg = "PreToolUse hook returned permissionDecision:deny" +
                    " without a non-empty permissionDecisionReason"
                hookLog.warn(msg)
                schemaError = msg
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
            }
        case .postToolUse, .sessionStart, .userPromptSubmit:
            out.additionalContext = (hso["additionalContext"] as? String)
                ?? (hso["additional_context"] as? String)
        case .preCompact, .postCompact, .stop:
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

        let timeoutSecs = min(max(def.timeoutSec, 1), 600)
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
            var decision: HookDecision = .allow
            if let dec = obj["decision"] as? String {
                let l = dec.lowercased()
                if l == "block" { decision = .block }
                else if l == "allow" { decision = .allow }
            }
            // P4.6 / H-29: Stop-hook semantic. Upstream's `events/stop.rs`
            // treats `continue: false` as "terminate the session" and
            // `decision: "block"` (with a non-empty reason) as "inject the
            // reason as a continuation prompt and re-enter sampling". The
            // legacy collapse to `.block` is preserved for the aggregate /
            // blockingReason API surface, but the new dedicated fields
            // (`shouldStop`, `shouldBlock`, `continuationPrompt`) carry the
            // full upstream signal for the SessionEngine to act on.
            var shouldStop = false
            var stopReason: String?
            var shouldBlock = false
            var continuationPrompt: String?
            if let cont = obj["continue"] as? Bool, cont == false {
                decision = .block
                if req.eventName == .stop {
                    shouldStop = true
                    stopReason = (obj["stopReason"] as? String)
                        ?? (obj["stop_reason"] as? String)
                }
            }
            if let blk = obj["block"] as? Bool, blk == true { decision = .block }
            let reason = obj["reason"] as? String
            // Stop-hook decision:block — only honored when reason is non-empty
            // (upstream `events/stop.rs::parse_completed`, line 173-194).
            // `shouldStop` (continue:false) wins over `shouldBlock`.
            if req.eventName == .stop,
               !shouldStop,
               let dec = obj["decision"] as? String,
               dec.lowercased() == "block" {
                let trimmedReason = (reason ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedReason.isEmpty {
                    shouldBlock = true
                    continuationPrompt = trimmedReason
                }
            }
            let sysMsg = (obj["systemMessage"] as? String)
                ?? (obj["system_message"] as? String)
            // Parse `hookSpecificOutput` (modern protocol). Fall back to flat
            // legacy `additionalContext` if no structured form is present.
            let (hso, flatAddCtx, schemaError) = Self.parseHookSpecificOutput(obj, event: req.eventName)
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

        if result.exitCode == 2 {
            let txt = result.stderr.isEmpty ? trimmed : result.stderr
            // Stop-hook exit-2: upstream treats stderr as the continuation
            // prompt (events/stop.rs:203-222), NOT as a session terminator.
            if req.eventName == .stop, !txt.isEmpty {
                return HookOutcome(
                    decision: .block,
                    reason: txt,
                    shouldBlock: true,
                    continuationPrompt: txt,
                    raw: raw)
            }
            // P4.6 cosmetic parity (events/stop.rs:213-220): a Stop hook that
            // exits with code 2 but writes nothing to stderr is treated
            // upstream as `HookRunStatus::Failed` with NO block signal — the
            // session is allowed to terminate as planned. The intermediate
            // outcome therefore carries `decision: .allow` / `shouldBlock:
            // false` (no continuation injected) and surfaces the divergence
            // via `outputSchemaError` so callers / tests can still detect the
            // failed run.
            if req.eventName == .stop {
                return HookOutcome(
                    decision: .allow,
                    reason: nil,
                    outputSchemaError:
                        "Stop hook exited with code 2 but did not write a continuation prompt to stderr",
                    raw: raw)
            }
            return HookOutcome(
                decision: .block,
                reason: txt.isEmpty ? "blocked by hook (exit 2)" : txt,
                raw: raw)
        }

        return HookOutcome(decision: .allow, reason: nil, raw: raw)
    }
}
