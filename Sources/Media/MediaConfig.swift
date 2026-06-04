import Foundation
import Config

/// Reads `[media]` from the merged addon config. Pure + testable (lives in the
/// library so the deny-default gate is unit-testable, not buried in the
/// executable's composition root).
///
/// Deny-default: `load` returns nil unless `[features].media` is on. For a
/// non-stub provider the API-key env var must be SET (a misconfigured key is a
/// nil → the pack self-prunes, byte-identical to feature-off), so we never
/// advertise a tool that would fail every call.
public struct MediaConfig: Sendable, Equatable {
    /// "stub" (MVP, inline placeholder generator) or a future async backend
    /// ("openai" / "fal", which REQUIRE the daemon poller + in-process workers).
    public let provider: String
    /// Where generated assets are written. MUST be the same path the WebGateway
    /// `/media` route serves from, or a minted URL 404s — see MediaWiring.
    public let mediaRoot: String
    /// The NAME of the env var holding the provider API key — never the key.
    public let apiKeyEnv: String?

    public init(provider: String, mediaRoot: String, apiKeyEnv: String?) {
        self.provider = provider
        self.mediaRoot = mediaRoot
        self.apiKeyEnv = apiKeyEnv
    }

    public static func load(config: Config, codexHome: String,
                            env: [String: String]) -> MediaConfig? {
        // Pass `env` through so the CODEX_FEATURE_MEDIA override honors the
        // SAME environment the rest of the read uses (not the process default).
        guard config.isFeatureEnabled("media", env: env) else { return nil }
        let obj = config.value("media")?.objectValue ?? [:]
        let provider = obj["provider"]?.stringValue ?? "stub"
        let root = (obj["media_root"]?.stringValue).map { expandHome($0, codexHome) }
            ?? (codexHome + "/media")
        let apiKeyEnv = obj["api_key_env"]?.stringValue
        // A non-stub (async, network) provider can't run without its key — fail
        // closed to nil rather than advertise a tool that errors every call.
        if provider != "stub" {
            guard let keyEnv = apiKeyEnv, let v = env[keyEnv], !v.isEmpty else { return nil }
        }
        return MediaConfig(provider: provider, mediaRoot: root, apiKeyEnv: apiKeyEnv)
    }

    /// The config layer does NOT expand `$CODEX_HOME`; do it here.
    static func expandHome(_ p: String, _ codexHome: String) -> String {
        p.replacingOccurrences(of: "$CODEX_HOME", with: codexHome)
    }
}
