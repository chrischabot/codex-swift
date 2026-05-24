import Foundation
import WireProtocol

/// Codex `GranularApprovalConfig` (upstream `protocol::GranularApprovalConfig`).
///
/// Carried by `ApprovalPolicy.granular(_:)`. Each boolean independently gates a
/// category of approval prompts: when `false` the corresponding category is
/// auto-rejected instead of surfaced to the user, when `true` the prompt is
/// allowed to fire as normal.
///
/// Wire format mirrors upstream (snake_case fields):
/// `{"sandbox_approval": Bool, "rules": Bool, "skill_approval": Bool,
///  "request_permissions": Bool, "mcp_elicitations": Bool}`.
/// The three trailing fields default to `false` if omitted (matching
/// `#[serde(default)]` on the Rust side).
public struct GranularApprovalConfig: Sendable, Codable, Equatable, Hashable {
    /// Whether shell command approval requests (including inline
    /// `with_additional_permissions` and `require_escalated` requests) may
    /// prompt the user.
    public var sandboxApproval: Bool
    /// Whether prompts triggered by execpolicy `prompt` rules may fire.
    public var rules: Bool
    /// Whether approval prompts triggered by skill script execution may fire.
    public var skillApproval: Bool
    /// Whether prompts triggered by the `request_permissions` tool may fire.
    public var requestPermissions: Bool
    /// Whether MCP elicitation prompts may fire.
    public var mcpElicitations: Bool

    public init(sandboxApproval: Bool,
                rules: Bool,
                skillApproval: Bool = false,
                requestPermissions: Bool = false,
                mcpElicitations: Bool) {
        self.sandboxApproval = sandboxApproval
        self.rules = rules
        self.skillApproval = skillApproval
        self.requestPermissions = requestPermissions
        self.mcpElicitations = mcpElicitations
    }

    public var allowsSandboxApproval: Bool { sandboxApproval }
    public var allowsRulesApproval: Bool { rules }
    public var allowsSkillApproval: Bool { skillApproval }
    public var allowsRequestPermissions: Bool { requestPermissions }
    public var allowsMcpElicitations: Bool { mcpElicitations }

    enum CodingKeys: String, CodingKey {
        case sandboxApproval = "sandbox_approval"
        case rules
        case skillApproval = "skill_approval"
        case requestPermissions = "request_permissions"
        case mcpElicitations = "mcp_elicitations"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sandboxApproval = try c.decode(Bool.self, forKey: .sandboxApproval)
        self.rules = try c.decode(Bool.self, forKey: .rules)
        // `#[serde(default)]` on upstream — tolerate missing values.
        self.skillApproval = (try? c.decodeIfPresent(Bool.self, forKey: .skillApproval)) ?? false
        self.requestPermissions = (try? c.decodeIfPresent(Bool.self,
                                                          forKey: .requestPermissions)) ?? false
        self.mcpElicitations = try c.decode(Bool.self, forKey: .mcpElicitations)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sandboxApproval, forKey: .sandboxApproval)
        try c.encode(rules, forKey: .rules)
        try c.encode(skillApproval, forKey: .skillApproval)
        try c.encode(requestPermissions, forKey: .requestPermissions)
        try c.encode(mcpElicitations, forKey: .mcpElicitations)
    }
}

/// Codex approval policy (`codex_protocol` `AskForApproval`). Gates whether a
/// command/patch runs sandboxed, runs unsandboxed after consent, or is shed.
///
/// Wire format: upstream's `AskForApproval` serializes with
/// `#[serde(rename_all = "kebab-case")]` and the `UnlessTrusted` variant is
/// renamed to `"untrusted"` (see
/// `codex-rs/app-server-protocol/src/protocol/v2/shared.rs`). For backwards
/// compatibility with older clients / config files we also accept
/// `"unless-trusted"` and a few aliases on decode.
///
/// The `granular` variant carries a `GranularApprovalConfig` and serialises as
/// the externally-tagged form `{"granular": {<config>}}` — matching upstream's
/// `AskForApproval::Granular(GranularApprovalConfig)` enum variant.
public enum ApprovalPolicy: Sendable, Codable, Equatable, Hashable {
    /// Never escalate; commands run only in the sandbox (no approval prompts).
    case never
    /// Escalate everything except a small allowlist of safe "read" commands.
    /// Wire value is upstream's `"untrusted"` — see Codex
    /// `AskForApproval::UnlessTrusted`.
    case unlessTrusted
    /// Run sandboxed; on a sandbox failure, ask to re-run unsandboxed.
    case onFailure
    /// Run sandboxed; ask when the model requests escalation or the action
    /// would write outside the writable roots / is not a safe command.
    case onRequest
    /// Fine-grained per-category approval gates. Each boolean in the carried
    /// `GranularApprovalConfig` independently controls whether prompts of that
    /// category may fire (`true`) or are auto-rejected (`false`). Mirrors
    /// upstream `AskForApproval::Granular(GranularApprovalConfig)`.
    case granular(GranularApprovalConfig)

    public static let `default`: ApprovalPolicy = .onRequest

    /// String discriminator for the non-payload-carrying variants. Used to
    /// match upstream's `AskForApproval` `Display` impl and for embedding the
    /// policy into envelopes that historically expected a flat string.
    /// `granular` returns `"granular"` (the discriminator alone — callers that
    /// need the structured form should use ``encode(to:)``).
    public var wireValue: String {
        switch self {
        case .never: return "never"
        case .unlessTrusted: return "untrusted"
        case .onFailure: return "on-failure"
        case .onRequest: return "on-request"
        case .granular: return "granular"
        }
    }

    public init(fromOptional raw: String?) {
        switch raw?.lowercased() {
        case "never": self = .never
        case "untrusted", "unless-trusted", "unlesstrusted": self = .unlessTrusted
        case "on-failure", "onfailure", "failure": self = .onFailure
        case "on-request", "onrequest", "request": self = .onRequest
        // A bare `"granular"` string with no payload defaults to an
        // all-permissive granular config (every category may prompt) — this
        // matches the upstream `Default` impl behaviour and keeps callers
        // that thread a string-only API path from regressing to onRequest.
        case "granular":
            self = .granular(GranularApprovalConfig(
                sandboxApproval: true, rules: true,
                skillApproval: true, requestPermissions: true,
                mcpElicitations: true))
        default: self = .default
        }
    }

    /// Tolerant `Decodable` that accepts:
    ///   - A bare string for the four simple variants (canonical upstream
    ///     wire value `"untrusted"`, legacy Swift `"unless-trusted"`,
    ///     `"never"` / `"on-failure"` / `"on-request"`, plus fuzzy aliases).
    ///   - A bare string `"granular"` (defaults to all-permissive config).
    ///   - An externally-tagged object `{"granular": {<config>}}` for the
    ///     full granular payload.
    /// Falls back to ``ApprovalPolicy/default`` for unknown bare-string
    /// values rather than throwing — config files have historically been
    /// permissive here.
    public init(from decoder: any Decoder) throws {
        // Single-value (string) form, e.g. "never", "untrusted", "granular".
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            self = ApprovalPolicy(fromOptional: raw)
            return
        }
        // Structured `{"granular": {<config>}}` form.
        let c = try decoder.container(keyedBy: ObjectKey.self)
        if let key = c.allKeys.first {
            switch key.stringValue {
            case "granular":
                let cfg = try c.decode(GranularApprovalConfig.self, forKey: key)
                self = .granular(cfg)
                return
            default:
                self = ApprovalPolicy(fromOptional: key.stringValue)
                return
            }
        }
        self = .default
    }

    /// Encoding mirrors upstream's externally-tagged kebab-case enum:
    ///   - simple variants emit a bare string;
    ///   - `granular(_:)` emits `{"granular": {<config>}}`.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .never, .unlessTrusted, .onFailure, .onRequest:
            var c = encoder.singleValueContainer()
            try c.encode(wireValue)
        case .granular(let cfg):
            var c = encoder.container(keyedBy: ObjectKey.self)
            try c.encode(cfg, forKey: ObjectKey(stringValue: "granular")!)
        }
    }

    private struct ObjectKey: CodingKey, Equatable {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// Codex sandbox mode (`codex_protocol` `SandboxPolicy`/`SandboxMode`).
///
/// This is the legacy hyphenated string form Swift has used historically for
/// the `sandbox` field in `thread/start` / `thread/resume` params. For the
/// structured tagged-enum wire format see ``SandboxPolicy`` below.
public enum SandboxModeKind: String, Sendable, Codable, Equatable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    public init(fromOptional raw: String?) {
        switch raw?.lowercased() {
        case "read-only", "readonly", "readOnly".lowercased(): self = .readOnly
        case "danger-full-access", "dangerfullaccess", "full",
             "danger_full_access": self = .dangerFullAccess
        default: self = .workspaceWrite
        }
    }
}

// MARK: - SandboxPolicy (tagged-enum wire format)

/// Whether outbound network access is available to a sandboxed agent. Wire
/// values match upstream `NetworkAccess` (`"restricted"` | `"enabled"`).
public enum NetworkAccess: String, Sendable, Codable, Equatable {
    case restricted
    case enabled

    public var isEnabled: Bool { self == .enabled }
}

/// Codex `SandboxPolicy` (v2 app-server protocol). Tagged-enum wire format
/// emitted by upstream as `{"type": "<variant>", ...fields}` with camelCase
/// tags and field names. Source:
/// `codex-rs/app-server-protocol/src/protocol/v2/permissions.rs`.
///
/// Encoding always produces the tagged form. Decoding accepts both the
/// tagged form and the legacy plain-string form (`"workspace-write"` /
/// `"read-only"` / `"danger-full-access"`) for backwards compatibility with
/// older Swift clients that used `SandboxModeKind.rawValue` directly.
public enum SandboxPolicy: Sendable, Codable, Equatable {
    case dangerFullAccess
    case readOnly(networkAccess: Bool = false)
    case workspaceWrite(writableRoots: [String] = [],
                        networkAccess: Bool = false,
                        excludeTmpdirEnvVar: Bool = false,
                        excludeSlashTmp: Bool = false)
    /// The process is already in an external sandbox (e.g. Linux Landlock).
    /// Mirrors upstream `SandboxPolicy::ExternalSandbox`.
    case externalSandbox(networkAccess: NetworkAccess = .restricted)

    /// The legacy `SandboxModeKind` for this policy, suitable for emitting on
    /// fields that still expect the flat hyphenated string. `externalSandbox`
    /// is treated as `dangerFullAccess` for the legacy projection because the
    /// legacy enum has no corresponding variant.
    public var modeKind: SandboxModeKind {
        switch self {
        case .dangerFullAccess, .externalSandbox: return .dangerFullAccess
        case .readOnly: return .readOnly
        case .workspaceWrite: return .workspaceWrite
        }
    }

    private enum WireKey: String, CodingKey {
        case type
        case writableRoots
        case networkAccess
        case excludeTmpdirEnvVar
        case excludeSlashTmp
    }

    private enum WireTag: String {
        case dangerFullAccess
        case readOnly
        case workspaceWrite
        case externalSandbox
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .dangerFullAccess:
            try c.encode(WireTag.dangerFullAccess.rawValue, forKey: .type)
        case .readOnly(let net):
            try c.encode(WireTag.readOnly.rawValue, forKey: .type)
            try c.encode(net, forKey: .networkAccess)
        case .workspaceWrite(let roots, let net, let excludeTmp, let excludeSlash):
            try c.encode(WireTag.workspaceWrite.rawValue, forKey: .type)
            try c.encode(roots, forKey: .writableRoots)
            try c.encode(net, forKey: .networkAccess)
            try c.encode(excludeTmp, forKey: .excludeTmpdirEnvVar)
            try c.encode(excludeSlash, forKey: .excludeSlashTmp)
        case .externalSandbox(let net):
            try c.encode(WireTag.externalSandbox.rawValue, forKey: .type)
            try c.encode(net, forKey: .networkAccess)
        }
    }

    public init(from decoder: any Decoder) throws {
        // Accept the legacy plain-string form first.
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            switch raw.lowercased() {
            case "danger-full-access", "dangerfullaccess", "danger_full_access":
                self = .dangerFullAccess; return
            case "read-only", "readonly":
                self = .readOnly(networkAccess: false); return
            case "workspace-write", "workspacewrite":
                self = .workspaceWrite(); return
            case "external-sandbox", "externalsandbox":
                self = .externalSandbox(); return
            default:
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown SandboxPolicy string: \(raw)")
            }
        }
        let c = try decoder.container(keyedBy: WireKey.self)
        let typeRaw = try c.decode(String.self, forKey: .type)
        switch Self.normalizeTag(typeRaw) {
        case "dangerFullAccess":
            self = .dangerFullAccess
        case "readOnly":
            let net = (try? c.decodeIfPresent(Bool.self, forKey: .networkAccess)) ?? false
            self = .readOnly(networkAccess: net)
        case "workspaceWrite":
            let roots = (try? c.decodeIfPresent([String].self, forKey: .writableRoots)) ?? []
            let net = (try? c.decodeIfPresent(Bool.self, forKey: .networkAccess)) ?? false
            let excludeTmp = (try? c.decodeIfPresent(Bool.self,
                                                     forKey: .excludeTmpdirEnvVar)) ?? false
            let excludeSlash = (try? c.decodeIfPresent(Bool.self,
                                                       forKey: .excludeSlashTmp)) ?? false
            self = .workspaceWrite(writableRoots: roots, networkAccess: net,
                                    excludeTmpdirEnvVar: excludeTmp,
                                    excludeSlashTmp: excludeSlash)
        case "externalSandbox":
            let net = (try? c.decodeIfPresent(NetworkAccess.self,
                                              forKey: .networkAccess)) ?? .restricted
            self = .externalSandbox(networkAccess: net)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: WireKey.type, in: c,
                debugDescription: "Unknown SandboxPolicy tag: \(typeRaw)")
        }
    }

    /// Accept both the camelCase upstream tags and a few hyphen / snake
    /// variants we have seen in the wild.
    private static func normalizeTag(_ raw: String) -> String {
        switch raw {
        case "dangerFullAccess", "danger-full-access", "danger_full_access":
            return "dangerFullAccess"
        case "readOnly", "read-only", "read_only":
            return "readOnly"
        case "workspaceWrite", "workspace-write", "workspace_write":
            return "workspaceWrite"
        case "externalSandbox", "external-sandbox", "external_sandbox":
            return "externalSandbox"
        default: return raw
        }
    }
}

extension SandboxPolicy {
    /// Project to a `JSONValue` for embedding in untyped response envelopes.
    public func toJSONValue() -> JSONValue {
        // Round-trip through Codable to guarantee identical wire bytes.
        do { return try JSONBridge.value(self) } catch {
            // Encoding can't fail for any concrete variant; fall back to a
            // minimal `{"type": "dangerFullAccess"}` shape if it ever does.
            return .object(["type": .string("dangerFullAccess")])
        }
    }

    /// Build a structured policy from a flat `SandboxModeKind` + writable
    /// roots / network access (the shape `SessionConfig` carries).
    public static func from(mode: SandboxModeKind,
                            writableRoots: [String] = [],
                            networkAccess: Bool = false) -> SandboxPolicy {
        switch mode {
        case .dangerFullAccess: return .dangerFullAccess
        case .readOnly: return .readOnly(networkAccess: networkAccess)
        case .workspaceWrite:
            return .workspaceWrite(writableRoots: writableRoots,
                                   networkAccess: networkAccess)
        }
    }
}
