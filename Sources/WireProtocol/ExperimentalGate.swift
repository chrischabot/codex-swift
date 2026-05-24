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
///   against `fields`/`enumVariants`. The returned descriptor is
///   method-qualified (`"method.field=variant"`) for the error message,
///   while the registry itself stores the unqualified marker. This keeps
///   schema-shape knowledge in the typed decode layer (ProtocolModel) and
///   the policy here.
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
    ]
    public static let defaultFields: Set<String> = [
        "thread/start.mockExperimentalField",
        "thread/start.runtimeWorkspaceRoots",
        "thread/start.environments",
        "thread/resume.excludeTurns",
        "thread/fork.excludeTurns",
        "turn/start.runtimeWorkspaceRoots",
        "turn/start.environments",
    ]
    public static let defaultEnumVariants: Set<String> = [
        "askForApproval=granular",
        "approvalPolicy=granular",
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
                if enumVariants.contains(f) { return "\(method).\(f)" }
            } else {
                let key = "\(method).\(f)"
                if fields.contains(key) { return key }
            }
        }
        return nil
    }
}
