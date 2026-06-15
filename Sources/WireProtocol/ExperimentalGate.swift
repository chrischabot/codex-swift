import Foundation

/// Negotiated per connection at `initialize` (port-eval §2.3).
public struct ClientCapabilities: Sendable, Equatable, Codable {
    public var experimentalApi: Bool
    public var optOutNotificationMethods: Set<String>
    public var requestAttestation: Bool
    public init(experimentalApi: Bool = false,
                optOutNotificationMethods: Set<String> = [],
                requestAttestation: Bool = false) {
        self.experimentalApi = experimentalApi
        self.optOutNotificationMethods = optOutNotificationMethods
        self.requestAttestation = requestAttestation
    }

    enum CodingKeys: String, CodingKey {
        case experimentalApi, optOutNotificationMethods, requestAttestation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.experimentalApi =
            try c.decodeIfPresent(Bool.self, forKey: .experimentalApi) ?? false
        self.optOutNotificationMethods =
            try c.decodeIfPresent(Set<String>.self, forKey: .optOutNotificationMethods) ?? []
        self.requestAttestation =
            try c.decodeIfPresent(Bool.self, forKey: .requestAttestation) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(experimentalApi, forKey: .experimentalApi)
        try c.encodeIfPresent(optOutNotificationMethods.isEmpty ? nil : optOutNotificationMethods,
                              forKey: .optOutNotificationMethods)
        try c.encode(requestAttestation, forKey: .requestAttestation)
    }
}

/// Data-driven experimental gate (mirrors `codex-experimental-api-macros`).
///
/// Descriptor kinds (port-eval §4.7):
/// - **method**: the whole method is experimental (`methods`).
/// - **field**: a top-level params field (`fields`, keyed `"method.field"`).
/// - **enum-variant**: an experimental enum case (`enumVariants`, keyed by
///   the unqualified `"field=variant"` marker, e.g. `"approvalPolicy=granular"`).
/// - **nested**: a nested field path. Callers flatten nested/enum
///   experimental surfaces into the `presentFields` argument using dotted
///   paths (e.g. `"profile.approvalPolicy"`) and `"field=variant"` enum
///   markers before calling `rejectionDescriptor`; the gate matches them
///   against `fields`/`enumVariants`. For **field** descriptors the returned
///   value is method-qualified (`"method.field"`) for the error message, while
///   the registry itself stores the unqualified marker. For **enum-variant**
///   descriptors the returned reason is the fixed, method-independent string
///   carried by the upstream `#[experimental("…")]` annotation on the variant
///   (e.g. `askForApproval=granular` → `askForApproval.granular`), looked up via
///   `enumVariantReasons`. This keeps schema-shape knowledge in the typed
///   decode layer (ProtocolModel) and the policy here.
public struct ExperimentalGate: Sendable {
    public private(set) var methods: Set<String>
    public private(set) var fields: Set<String>        // "method.field" / "a.b.c"
    public private(set) var enumVariants: Set<String>  // "method.field=variant"

    public init(methods: Set<String> = ExperimentalGate.defaultMethods,
                fields: Set<String> = ExperimentalGate.defaultFields,
                enumVariants: Set<String> = ExperimentalGate.defaultEnumVariants) {
        self.methods = methods
        self.fields = fields
        self.enumVariants = enumVariants
    }

    // Whole-method experimental requests — mirrors the `#[experimental(...)]`
    // markers on request variants in upstream `client_request_definitions!`
    // (app-server-protocol/src/protocol/common.rs).
    public static let defaultMethods: Set<String> = [
        "thread/turns/list",
        "thread/turns/items/list",
        "thread/memoryMode/set",
        "memory/reset",
        "thread/backgroundTerminals/clean",
        "process/spawn",
        "process/writeStdin",
        "process/kill",
        "process/resizePty",
        "mock/experimentalMethod",
        "environment/add",
        // Elicitation pause counters are experimental upstream and have no
        // capability-free callers in this port.
        "thread/increment_elicitation",
        "thread/decrement_elicitation",
        // Whole-method `#[experimental(...)]` markers from upstream
        // app-server-protocol/src/protocol/common.rs:497-1052. Upstream rejects
        // these with `<method> requires experimentalApi capability` (-32600)
        // when the connection did not negotiate `experimentalApi`.
        //
        // NOTE: `thread/goal/{set,get,clear}` were REMOVED here for the 2026-06
        // sync — upstream #23732 promoted the Goals feature to `Stage::Stable`
        // (`default_enabled: true`) and dropped the `#[experimental(...)]` markers
        // from the ThreadGoal* request variants (common.rs:533-546 at dfd03ea01b
        // carry no experimental attribute). Goals are now reachable without the
        // experimentalApi capability, matching upstream.
        "thread/realtime/start",
        "thread/realtime/appendAudio",
        "thread/realtime/appendText",
        "thread/realtime/stop",
        "thread/realtime/listVoices",
        "remoteControl/enable",
        "remoteControl/disable",
        "remoteControl/status/read",
        "collaborationMode/list",
        "fuzzyFileSearch/sessionStart",
        "fuzzyFileSearch/sessionUpdate",
        "fuzzyFileSearch/sessionStop",
    ]
    // Field-level experimental params — keyed `"method.field"` (camelCase wire
    // name). Mirrors the field `#[experimental(...)]` annotations across
    // app-server-protocol/src/protocol/v2/*.rs.
    public static let defaultFields: Set<String> = [
        "thread/start.mockExperimentalField",
        "thread/start.runtimeWorkspaceRoots",
        "thread/start.environments",
        "thread/start.permissions",
        "thread/start.dynamicTools",
        "thread/start.experimentalRawEvents",
        "thread/start.persistFullHistory",
        "thread/start.activePermissionProfile",
        "thread/resume.excludeTurns",
        "thread/resume.history",
        "thread/resume.path",
        "thread/resume.permissions",
        "thread/resume.persistFullHistory",
        "thread/resume.runtimeWorkspaceRoots",
        "thread/resume.activePermissionProfile",
        "thread/fork.excludeTurns",
        "thread/fork.path",
        "thread/fork.permissions",
        "thread/fork.persistFullHistory",
        "thread/fork.runtimeWorkspaceRoots",
        "thread/fork.activePermissionProfile",
        "turn/start.runtimeWorkspaceRoots",
        "turn/start.environments",
        "turn/start.permissions",
        "turn/start.collaborationMode",
        "turn/start.responsesapiClientMetadata",
        "turn/steer.responsesapiClientMetadata",
        "command/exec.permissionProfile",
        "config/read.approvalsReviewer",
        "config/read.apps",
        "account/login/start.chatgptAuthTokens",
    ]
    public static let defaultEnumVariants: Set<String> = [
        "askForApproval=granular",
        "approvalPolicy=granular",
    ]

    /// Maps an enum-variant marker (`"field=variant"`) to the fixed,
    /// method-independent reason string that upstream's
    /// `experimental_required_message` reports. Upstream marks the
    /// `AskForApproval::Granular` variant `#[experimental("askForApproval.granular")]`
    /// (app-server-protocol/src/protocol/v2/shared.rs:168), so the rejection
    /// reason is the literal `"askForApproval.granular"` regardless of which
    /// method/field carried it (tests.rs:1481-1745). The `approvalPolicy`
    /// alias maps to the same reason.
    static let enumVariantReasons: [String: String] = [
        "askForApproval=granular": "askForApproval.granular",
        "approvalPolicy=granular": "askForApproval.granular",
    ]

    public func isExperimentalMethod(_ method: String) -> Bool { methods.contains(method) }

    /// Returns the gating descriptor that should reject this request, or nil
    /// if allowed for `caps`. `presentFields` is the caller-flattened set of
    /// dotted field paths and `"field=variant"` enum markers actually present
    /// in the request.
    public func rejectionDescriptor(method: String,
                                    presentFields: [String],
                                    caps: ClientCapabilities) -> String? {
        if caps.experimentalApi { return nil }
        if methods.contains(method) { return method }
        for f in presentFields {
            if f.contains("=") {
                if enumVariants.contains(f) {
                    // Enum-variant gates carry a fixed, method-independent reason
                    // (upstream `#[experimental("…")]` on the variant), unlike
                    // method/field descriptors which are method-qualified.
                    return ExperimentalGate.enumVariantReasons[f] ?? f
                }
            } else {
                let key = "\(method).\(f)"
                if fields.contains(key) { return key }
            }
        }
        return nil
    }
}
