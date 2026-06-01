import Foundation

/// Mirrors `codex_protocol::config_types::Personality`. Codex resolves a
/// per-model default; for the gpt-5.x-codex family the shipped personalities
/// are `friendly` and `pragmatic`, with `pragmatic` as the effective default.
///
/// INTENTIONAL OMISSION — personality migration. Upstream
/// `core/src/personality_migration.rs::maybe_migrate_personality` performs a
/// one-time config-file seeding: for pre-existing users with no explicit
/// personality and prior recorded sessions, it writes a
/// `~/.codex/.personality_migration` marker (`"v1\n"`) and persists
/// `personality = pragmatic` into config.toml. The portable engine instead
/// resolves an unset personality to `pragmatic` at runtime (see
/// `Personality.default` / `Personality.resolve` below) WHEN the (default-on)
/// `personality` feature is enabled — and to the empty `personality_default`
/// fragment (modeled as `.none`) when that feature is explicitly disabled,
/// matching `config/mod.rs:3097-3104` + `get_personality_message(None)`. The
/// OBSERVABLE model behavior therefore matches the migration's outcome. The
/// marker/config-write is purely for
/// codex_home parity with the real Codex CLI (so other tools see the
/// persisted value) and depends on StateDb/ThreadStore/ConfigEditsBuilder
/// machinery that is out of scope here; it is deliberately not ported.
public enum Personality: String, Sendable, Codable, Equatable, CaseIterable {
    case none
    case friendly
    case pragmatic

    public static let `default`: Personality = .pragmatic

    /// Wire-name used for catalog lookups: matches the suffix used in
    /// `models.json` `instructions_variables` keys
    /// (`personality_pragmatic`, `personality_friendly`, ...).
    public var catalogKey: String {
        switch self {
        case .none:      return "none"
        case .friendly:  return "friendly"
        case .pragmatic: return "pragmatic"
        }
    }

    /// The verbatim personality fragment substituted into the model
    /// instructions `{{ personality }}` slot for the legacy gpt-5.2-codex
    /// template path.
    ///
    /// Single source of truth: the bundled `ModelsCatalog`. We use the default
    /// model's (`gpt-5.5`) `personality_<id>` fragment so this legacy fallback
    /// can never drift from the catalog the modern model-aware path consults.
    /// The vendored `Templates.*` constants remain only as an offline last
    /// resort if the catalog resource fails to load.
    public var templateText: String {
        // Upstream `get_personality_message`: `Personality::None => String::new()`.
        // The `none` placeholder is always the empty string regardless of catalog
        // contents (models.json ships no `personality_none` key).
        if self == .none { return "" }
        if let frag = ModelsCatalog.entry(for: "gpt-5.5")?
            .instructionsVariables["personality_\(catalogKey)"], !frag.isEmpty {
            return frag
        }
        switch self {
        case .none:      return ""
        case .friendly:  return Templates.personalityFriendly
        case .pragmatic: return Templates.personalityPragmatic
        }
    }

    public init(fromOptional raw: String?) {
        self = Personality.resolve(fromOptional: raw, personalityFeatureEnabled: true)
    }

    /// Faithful port of upstream config resolution
    /// (`config/mod.rs:3097-3104`): an explicit personality (override → profile
    /// → cfg) wins; otherwise the unset personality resolves to
    /// `Pragmatic` ONLY when the (default-on) `personality` feature is enabled.
    /// When the feature is explicitly DISABLED and no personality is set,
    /// upstream leaves `personality = None`, and `get_personality_message(None)`
    /// (`openai_models.rs:407-417`) returns the empty `personality_default`
    /// fragment. The `models.json` `personality_default` is the empty string
    /// everywhere, and `Personality.none` already resolves to the empty fragment
    /// (the catalog explicitly skips the `personality_default` fallback for
    /// `none`), so the feature-disabled outcome is reproduced by resolving an
    /// unset personality to `.none` rather than forcing `.pragmatic`.
    public static func resolve(fromOptional raw: String?,
                               personalityFeatureEnabled: Bool) -> Personality {
        switch raw?.lowercased() {
        case "none": return .none
        case "friendly": return .friendly
        case "pragmatic": return .pragmatic
        default:
            // Unset: pragmatic when the feature is on (the shipped default),
            // empty `personality_default` (modeled as `.none`) when disabled.
            return personalityFeatureEnabled ? .default : .none
        }
    }
}