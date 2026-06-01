import Foundation
import Config
import ProtocolModel
import ExtensionAPI

// Extension spine composition (docs/extensions/ARCHITECTURE.md §5.4, §6.5,
// §11 Phase 0). This file owns the cheap, self-describing `ExtensionManifest`
// (principle 4 / L6), the `[extensions]` config-table parse, and the single
// `installAddons(...)` composition-root entry point that turns the enabled
// manifests into an `ExtensionRegistry<SessionConfig>`.
//
// It lives in `HarnessCore` (not `ExtensionAPI`) deliberately: HarnessCore
// already depends on `Config`, so the manifest can reference `ConfigValue`
// without giving the otherwise dependency-free `ExtensionAPI` a `Config`
// dependency (seam-map "Option (b)": parse at the composition root, inject the
// built registry into the engine).
//
// Phase 0 ships with ZERO first-party features registered, so `installAddons`
// returns `nil` whenever the `extensions` feature is off or no manifest is
// enabled — and a `nil` registry makes every `SessionEngine` call-site a no-op,
// keeping core behavior byte-identical (verified by the wire-faithful tests).

/// One feature's cheap, declarable identity + capability metadata. Readable
/// without running the feature (ARCHITECTURE.md principle 4 / lesson L6): it
/// powers gating, config validation, and the future UI palette. Plain
/// `Codable` so it can be hand-decoded from the `[extensions]` TOML/`ConfigValue`
/// table or carried over the wire unchanged.
public struct ExtensionManifest: Sendable, Equatable, Codable {
    /// Stable feature id (e.g. "memory-wiki", "workflows"). Also the
    /// `[features]` / `CODEX_FEATURE_<ID>` gate key.
    public var id: String
    /// Human-facing name for the future UI palette.
    public var displayName: String
    /// Which extension seams this feature uses (e.g. "contextContributor",
    /// "turnLifecycle", "approvalReview", "tokenUsage"). Free-form strings so
    /// the manifest stays decoupled from the registry's Swift API.
    public var capabilities: [String]
    /// JSON-schema describing this feature's per-extension `[extensions.<id>]`
    /// options block. Free-form `ConfigValue` (nil when the feature takes no
    /// config).
    public var configSchema: ConfigValue?
    /// The swappable slot this feature claims, if any. Only `"memory"` exists
    /// today (D3). nil ⇒ the feature is purely additive (no exclusive slot).
    public var slot: String?
    /// Whether this manifest is enabled. Defaults to true; the per-table
    /// `enabled = false` key or the `extensions` feature gate can switch it off.
    public var enabled: Bool

    public init(id: String,
                displayName: String,
                capabilities: [String] = [],
                configSchema: ConfigValue? = nil,
                slot: String? = nil,
                enabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.configSchema = configSchema
        self.slot = slot
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, capabilities, configSchema, slot, enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? id
        capabilities = (try? c.decode([String].self, forKey: .capabilities)) ?? []
        configSchema = try? c.decode(ConfigValue.self, forKey: .configSchema)
        slot = try? c.decode(String.self, forKey: .slot)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }

    /// Hand-decode a single manifest from a `[[extensions]]` array entry /
    /// `[extensions.<id>]` table value (`ConfigValue`), matching the codebase's
    /// pattern-match-on-`ConfigValue` convention rather than going through
    /// `Codable` (the on-disk form is TOML→`ConfigValue`, not JSON).
    /// `fallbackId` supplies the id for the keyed-table form where the id is
    /// the table key rather than an inline `id` field.
    public init?(configValue v: ConfigValue, fallbackId: String? = nil) {
        guard case .object(let o) = v else { return nil }
        guard let id = o["id"]?.stringValue ?? fallbackId else { return nil }
        self.id = id
        self.displayName = o["display_name"]?.stringValue
            ?? o["displayName"]?.stringValue ?? id
        if case .array(let caps)? = o["capabilities"] {
            self.capabilities = caps.compactMap { $0.stringValue }
        } else {
            self.capabilities = []
        }
        self.configSchema = o["config_schema"] ?? o["configSchema"]
        self.slot = o["slot"]?.stringValue
        self.enabled = o["enabled"]?.boolValue ?? true
    }
}

/// Parse the `[extensions]` config table into manifests, tolerating both the
/// array-of-tables form (`[[extensions]]`, ordered, duplicate-id-tolerant —
/// matching `model_providers`) and the keyed-table form
/// (`[extensions.<id>]`). Returns `[]` when the key is absent or malformed.
public func parseExtensionManifests(from config: Config) -> [ExtensionManifest] {
    guard let raw = config.value("extensions") else { return [] }
    let parsed: [ExtensionManifest]
    switch raw {
    case .array(let entries):
        parsed = entries.compactMap { ExtensionManifest(configValue: $0) }
    case .object(let table):
        // Keyed-table form: `[extensions.<id>]` → each value is a table whose
        // key is the id. Sorted for deterministic ordering.
        parsed = table.sorted { $0.key < $1.key }.compactMap { key, value in
            ExtensionManifest(configValue: value, fallbackId: key)
        }
    default:
        return []
    }
    // Dedupe by id, first occurrence wins (D3 / lesson L3): two manifests with
    // the same id — and, once Phase 1 adds the slot registry, two claimants of
    // the same exclusive slot — must never both be processed. Deterministic
    // because both the array and sorted-table forms have stable order.
    var seen = Set<String>()
    return parsed.filter { seen.insert($0.id).inserted }
}

/// The single composition-root entry point (ARCHITECTURE.md §5.4, principle 3).
/// Called once per session from `makeComponents` in `codex-session` /
/// `codexd`. Builds an `ExtensionRegistry<SessionConfig>` from the enabled
/// manifests and returns it for installation on that session's `SessionEngine`.
///
/// Phase 0 registers NO first-party features, so the body is intentionally a
/// no-op aside from gating + manifest parsing: it returns `nil` whenever the
/// `extensions` feature is disabled or no manifest is enabled. A `nil` registry
/// keeps the engine byte-identical to the no-extension baseline.
///
/// Later phases append their `register(into:)` calls here (Memory slot, etc.)
/// — adding a feature touches this function + its own folder, nothing else
/// (lesson 9b).
public func installAddons(config: Config,
                          sessionConfig: SessionConfig,
                          memoryProvider: (any MemoryProvider)? = nil) -> ExtensionRegistry<SessionConfig>? {
    // Subsystem gate: the whole spine is opt-in behind the `extensions`
    // feature (`CODEX_FEATURE_EXTENSIONS` env or `[features].extensions` in
    // config.toml), defaulting to off — so the `[extensions]` table is
    // silently ignored unless explicitly enabled. Mirrors `WorkflowGating`.
    guard config.isFeatureEnabled("extensions") else { return nil }

    let manifests = parseExtensionManifests(from: config).filter { $0.enabled }
    let builder = ExtensionRegistryBuilder<SessionConfig>()

    // Phase 1: wire the selected Memory slot provider (recall → fenced
    // contextContributor; capture → turnLifecycle onStop). The composition root
    // selects the provider (`selectMemoryProvider`) and passes it here.
    if let memoryProvider { registerMemory(memoryProvider, into: builder) }

    // Future phases register more contributors against `builder` here, keyed on
    // each manifest's id / capabilities.
    _ = sessionConfig

    // Return a registry only when something is actually wired (a memory provider
    // or, for later phases, an enabled manifest). A nil registry keeps the
    // engine byte-identical to the no-extension baseline.
    if memoryProvider == nil && manifests.isEmpty { return nil }
    return builder.build()
}
