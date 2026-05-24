import Foundation

/// Mirrors `codex_protocol::config_types::Personality`. Codex resolves a
/// per-model default; for the gpt-5.x-codex family the shipped personalities
/// are `friendly` and `pragmatic`, with `pragmatic` as the effective default.
public enum Personality: String, Sendable, Codable, Equatable, CaseIterable {
    case friendly
    case pragmatic

    public static let `default`: Personality = .pragmatic

    /// The verbatim personality template substituted into the model
    /// instructions `{{ personality }}` slot.
    public var templateText: String {
        switch self {
        case .friendly:  return Templates.personalityFriendly
        case .pragmatic: return Templates.personalityPragmatic
        }
    }

    public init(fromOptional raw: String?) {
        switch raw?.lowercased() {
        case "friendly": self = .friendly
        case "pragmatic": self = .pragmatic
        default: self = .default
        }
    }
}