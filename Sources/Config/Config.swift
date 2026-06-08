import Foundation

/// A faithful JSON-ish config value (codex config is TOML; the portable
/// harness uses JSON to stay dependency-free — semantics are equivalent).
public indirect enum ConfigValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ConfigValue])
    case object([String: ConfigValue])

    public init(from d: any Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let x = try? c.decode(Double.self) { self = .double(x); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ConfigValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: ConfigValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad config value")
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let x): try c.encode(x)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        case .int(let i): return i != 0
        default: return nil
        }
    }
    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }
    public var objectValue: [String: ConfigValue]? {
        if case .object(let o) = self { return o }; return nil
    }
}

/// One named configuration layer (lowest precedence first). `source`
/// identifies the upstream `ConfigLayerSource` for `config/read` origins; it is
/// `nil` for the synthetic `defaults` layer, which upstream does not surface as
/// an origin (those keys are baked-in `ConfigToml` defaults, not a layer).
public struct ConfigLayer: Sendable, Equatable {
    public var name: String
    public var values: [String: ConfigValue]
    public var source: ConfigLayerSource?
    /// Set for a project-local layer whose directory is NOT explicitly trusted
    /// in the user's `[projects]` trust map (upstream `disabled_reason`,
    /// loader/mod.rs:828-844). A non-nil value means the layer is loaded but
    /// DISABLED: it contributes nothing to `merged`/`resolved`/`leafOrigins`
    /// (upstream `state.rs:497-510` filters `!layer.is_disabled()`), and the
    /// reason is surfaced on the `config/read` `layers[].disabledReason`
    /// (v2/config.rs:298-304). `nil` for every non-project layer and for
    /// trusted project layers.
    public var disabledReason: String?
    /// Convenience: whether this layer is disabled (upstream `is_disabled()`).
    public var isDisabled: Bool { disabledReason != nil }
    public init(name: String, values: [String: ConfigValue],
                source: ConfigLayerSource? = nil,
                disabledReason: String? = nil) {
        self.name = name; self.values = values; self.source = source
        self.disabledReason = disabledReason
    }
}

/// Deep-merged, origin-tracked configuration with feature flags. Pure value
/// type; loading/persistence are explicit.
public struct Config: Sendable, Equatable {
    /// Default project-doc cap (upstream `DEFAULT_PROJECT_DOC_MAX_BYTES`
    /// in `config_toml.rs`).
    public static let defaultProjectDocMaxBytes: Int64 = 32 * 1024

    public private(set) var merged: [String: ConfigValue]
    /// Top-level key → name of the layer that last set it (legacy/debug view).
    public private(set) var origins: [String: String]
    /// Dotted-leaf-path → `ConfigLayerMetadata` (upstream `config/read`
    /// `origins`). Only layers with a `source` contribute (synthetic defaults
    /// are excluded); the highest-precedence layer that set a leaf wins.
    public private(set) var leafOrigins: [String: ConfigLayerMetadata]
    /// The resolved named profile (codex `[profiles.<name>]`), if any.
    public private(set) var profileName: String?
    /// The selected inline `[profiles.<name>]` overlay table, captured at load
    /// time but NOT folded into `merged`/the config-layer view (matching
    /// upstream, which loads the base user layer RAW with `profile = None`).
    /// Applied ONLY at thread/session resolution — see `resolved`.
    public private(set) var profileOverlay: [String: ConfigValue]
    /// The session-time effective view: `merged` deep-merged with the selected
    /// inline `[profiles.<name>]` overlay on top. This is what thread/session
    /// resolution reads (so a profile's `model`, `model_reasoning_effort`, …
    /// still take effect), while the raw `merged` map (and the `config/read`
    /// projection built from it) stays un-overlaid and retains `[profiles]`.
    public private(set) var resolved: [String: ConfigValue]
    /// The layer stack this config was composed from (lowest precedence first),
    /// retained so `config/read` can surface `layers` when `includeLayers` is set.
    public private(set) var layers: [ConfigLayer]
    /// Startup warnings collected while composing the layer stack — currently
    /// the per-file project-local "ignored unsupported config keys" warnings
    /// (upstream `startup_warnings`, loader/mod.rs:1203-1218). Each is emitted
    /// to the client as a `configWarning` notification. A value type carries
    /// these out of the (sink-less) loader so a caller with a connection can
    /// emit them (matching upstream, which threads `startup_warnings` up to the
    /// app-server before fanning them out — app-server/src/lib.rs:582-593).
    public private(set) var configWarnings: [ConfigWarning]
    /// A hard configuration error surfaced during load (upstream returns these
    /// as `io::ErrorKind::InvalidData` from `load_config_layers_state`,
    /// loader/mod.rs:227-243). The Swift `load()` is non-throwing (it is called
    /// from many non-throwing sites), so a fatal load error rides out on the
    /// `Config` value here, carrying upstream's verbatim message; the offending
    /// layer is NOT applied. Currently used for the profile-v2 / legacy
    /// `[profiles.<name>]` collision (Finding 2). `nil` on the happy path.
    public private(set) var loadError: String?

    /// A single project-local "ignored config keys" warning. Mirrors the
    /// payload of upstream `ConfigWarningNotification` (summary/details/path).
    public struct ConfigWarning: Sendable, Equatable {
        public var summary: String
        public var details: String?
        public var path: String?
        public init(summary: String, details: String? = nil, path: String? = nil) {
            self.summary = summary; self.details = details; self.path = path
        }
    }

    public init(layers: [ConfigLayer],
                profileName: String? = nil,
                profileOverlay: [String: ConfigValue] = [:],
                configWarnings: [ConfigWarning] = [],
                loadError: String? = nil) {
        self.layers = layers
        self.configWarnings = configWarnings
        self.loadError = loadError
        var acc: [String: ConfigValue] = [:]
        var orig: [String: String] = [:]
        var leaves: [String: ConfigLayerMetadata] = [:]
        for layer in layers {
            // Disabled (untrusted project) layers are loaded but excluded from
            // the effective config — they contribute nothing to merged /
            // resolved / origins (upstream `state.rs:497-510` filters
            // `!layer.is_disabled()` in `get_layers`).
            if layer.isDisabled { continue }
            let meta: ConfigLayerMetadata? = layer.source.map {
                ConfigLayerMetadata(name: $0,
                                    version: ConfigCanonicalVersion.version(of: layer.values))
            }
            for (k, v) in layer.values {
                acc[k] = Config.deepMerge(acc[k], v)
                orig[k] = layer.name
                if let meta { Config.recordLeafOrigins(v, path: [k], meta: meta, into: &leaves) }
            }
        }
        self.merged = acc
        self.origins = orig
        self.leafOrigins = leaves
        self.profileName = profileName
        self.profileOverlay = profileOverlay
        // Session-time resolution: overlay the selected inline profile on top
        // of the merged config. With no profile selected this is identical to
        // `merged`.
        var res = acc
        for (k, v) in profileOverlay {
            res[k] = Config.deepMerge(res[k], v)
        }
        self.resolved = res
    }

    /// Upstream `record_origins` (config/src/fingerprint.rs): recurse into a
    /// layer value and record every scalar LEAF (and array-index leaf) at its
    /// dotted path → the layer's metadata. Tables/arrays recurse; scalars
    /// terminate. Later (higher-precedence) layers overwrite earlier entries.
    static func recordLeafOrigins(_ value: ConfigValue, path: [String],
                                  meta: ConfigLayerMetadata,
                                  into out: inout [String: ConfigLayerMetadata]) {
        switch value {
        case .object(let o):
            for (k, v) in o {
                recordLeafOrigins(v, path: path + [k], meta: meta, into: &out)
            }
        case .array(let a):
            for (idx, item) in a.enumerated() {
                recordLeafOrigins(item, path: path + [String(idx)], meta: meta, into: &out)
            }
        default:
            if !path.isEmpty { out[path.joined(separator: ".")] = meta }
        }
    }

    static func deepMerge(_ base: ConfigValue?, _ over: ConfigValue) -> ConfigValue {
        guard case .object(let b)? = base, case .object(let o) = over else {
            return over
        }
        var out = b
        for (k, v) in o { out[k] = deepMerge(b[k], v) }
        return .object(out)
    }

    // MARK: typed dotted-path accessors

    /// Typed dotted-path lookup over the SESSION-TIME effective view
    /// (`resolved` = merged + selected inline profile overlay). Session/thread
    /// resolution and runtime consumers read through here, so a selected
    /// `[profiles.<name>]` still applies. The raw (un-overlaid) config-layer map
    /// is available via `configObjectJSON()` / `configProjectionJSON()`, which
    /// power the `config/read` projection.
    public func value(_ path: String) -> ConfigValue? {
        var cur: ConfigValue? = nil
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        cur = resolved[first]
        for p in parts.dropFirst() {
            guard case .object(let o)? = cur else { return nil }
            cur = o[p]
        }
        return cur
    }
    public func string(_ path: String) -> String? { value(path)?.stringValue }
    public func bool(_ path: String) -> Bool? { value(path)?.boolValue }
    public func int(_ path: String) -> Int64? { value(path)?.intValue }

    public var model: String? { string("model") }
    // Upstream `ConfigToml` reads only snake_case `approval_policy` /
    // `sandbox_mode`; a top-level camelCase key is an unknown field that is
    // silently dropped (config_toml.rs:158/184). Do NOT read the camelCase form.
    public var approvalPolicy: String? { string("approval_policy") }
    public var sandboxMode: String? { string("sandbox_mode") }
    public var feedbackEnabled: Bool { bool("feedback.enabled") ?? true }

    // Mirrors of upstream `ConfigToml` defaults that surface via `config/read`
    // and are consumed by harness/runtime code paths. Each `??` value matches
    // the corresponding `default_*` helper in upstream's `config_toml.rs`.
    public var allowLoginShell: Bool { bool("allow_login_shell") ?? true }
    public var hideAgentReasoning: Bool { bool("hide_agent_reasoning") ?? false }
    /// `config.agents.interrupt_message` → upstream
    /// `agent_interrupt_message_enabled` (`core/src/config/mod.rs:2967-2971`,
    /// default `true`). Gates the interrupted-turn history marker.
    public var agentInterruptMessageEnabled: Bool {
        bool("agents.interrupt_message") ?? true
    }
    public var projectDocMaxBytes: Int64 {
        int("project_doc_max_bytes") ?? Config.defaultProjectDocMaxBytes
    }
    public var projectDocFallbackFilenames: [String] {
        guard case .array(let a)? = value("project_doc_fallback_filenames") else { return [] }
        return a.compactMap { $0.stringValue }
    }
    /// Configurable repo-root markers (upstream `project_root_markers`).
    /// `nil` means the user hasn't set the key — callers should fall back to
    /// `[".git"]` (upstream's `default_project_root_markers`).
    public var projectRootMarkers: [String]? {
        guard case .array(let a)? = value("project_root_markers") else { return nil }
        return a.compactMap { $0.stringValue }
    }
    /// Upstream `ConfigToml::model_auto_compact_token_limit`
    /// (`config_toml.rs:157` → `config/mod.rs:527`, `Option<i64>`): an optional
    /// user-configured override for the auto-compaction TRIGGER limit. When set
    /// it is min()'d against the model's 90%-context-window value (see
    /// `openai_models.rs:322` `auto_compact_token_limit()`); `nil` means the
    /// window-derived value is used verbatim. Default is unset.
    public var modelAutoCompactTokenLimit: Int? {
        int("model_auto_compact_token_limit").map(Int.init)
            ?? int("modelAutoCompactTokenLimit").map(Int.init)
    }
    public var historyPersistence: String {
        string("history.persistence") ?? "save-all"
    }
    public var historyMaxBytes: Int64? { int("history.max_bytes") }

    // MARK: feature flags (codex `features` + CODEX_FEATURE_* env)

    public func isFeatureEnabled(_ name: String,
                                 env: [String: String] = ProcessInfo.processInfo.environment)
    -> Bool {
        let envKey = "CODEX_FEATURE_"
            + name.uppercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_")
        if let e = env[envKey] {
            return ["1", "true", "yes", "on"].contains(e.lowercased())
        }
        if case .object(let feats)? = resolved["features"],
           let v = feats[name]?.boolValue {
            return v
        }
        return false
    }

    // MARK: wire shape for `config/read`

    public func configObjectJSON() -> [String: ConfigValue] { merged }

    /// Complete set of top-level keys that survive upstream's
    /// `effective.try_into::<ConfigToml>()` step (config_toml.rs:144-499). Any
    /// top-level key NOT in this set is silently DROPPED during the
    /// `try_into::<ConfigToml>()` projection, because `ConfigToml` has no
    /// top-level `#[serde(flatten)]` catch-all. This mirrors the exact field
    /// list of upstream `ConfigToml`.
    public static let configTomlTopLevelKeys: Set<String> = [
        "model", "review_model", "model_provider", "model_context_window",
        "model_auto_compact_token_limit", "approval_policy", "approvals_reviewer",
        "auto_review", "shell_environment_policy", "allow_login_shell",
        "sandbox_mode", "sandbox_workspace_write", "default_permissions",
        "permissions", "notify", "instructions", "developer_instructions",
        "include_permissions_instructions", "include_apps_instructions",
        "include_collaboration_mode_instructions", "include_environment_context",
        "model_instructions_file", "compact_prompt", "forced_chatgpt_workspace_id",
        "forced_login_method", "cli_auth_credentials_store", "mcp_servers",
        "mcp_oauth_credentials_store", "mcp_oauth_callback_port",
        "mcp_oauth_callback_url", "model_providers", "project_doc_max_bytes",
        "project_doc_fallback_filenames", "tool_output_token_limit",
        "background_terminal_max_timeout", "js_repl_node_path",
        "js_repl_node_module_dirs", "zsh_path", "profile", "profiles", "history",
        "sqlite_home", "log_dir", "debug", "file_opener", "tui",
        "hide_agent_reasoning", "show_raw_agent_reasoning", "model_reasoning_effort",
        "plan_mode_reasoning_effort", "model_reasoning_summary", "model_verbosity",
        "model_supports_reasoning_summaries", "model_catalog_json", "personality",
        "service_tier", "chatgpt_base_url", "apps_mcp_product_sku", "openai_base_url",
        "audio", "experimental_realtime_ws_base_url", "experimental_realtime_ws_model",
        "realtime", "experimental_realtime_ws_backend_prompt",
        "experimental_realtime_ws_startup_context",
        "experimental_realtime_start_instructions",
        "experimental_thread_config_endpoint", "experimental_thread_store_endpoint",
        "experimental_thread_store", "projects", "web_search", "tools",
        "tool_suggest", "agents", "memories", "skills", "hooks", "plugins",
        "marketplaces", "features", "suppress_unstable_features_warning",
        "ghost_snapshot", "project_root_markers", "check_for_update_on_startup",
        "disable_paste_burst", "analytics", "feedback", "apps", "desktop", "otel",
        "windows", "notice", "experimental_compact_prompt_file",
        "experimental_use_unified_exec_tool", "oss_provider",
    ]

    /// The v2 `Config` (ApiConfig) struct's NAMED fields
    /// (app-server-protocol/v2/config.rs:249-285), excluding the `additional`
    /// flatten catch-all. None of these carry `skip_serializing_if`, so an
    /// absent value is serialized as an explicit `null` (not omitted). They are
    /// therefore always present in `config/read.config`.
    static let v2ConfigNamedFields: [String] = [
        "model", "review_model", "model_context_window",
        "model_auto_compact_token_limit", "model_provider", "approval_policy",
        "approvals_reviewer", "sandbox_mode", "sandbox_workspace_write",
        "forced_chatgpt_workspace_id", "forced_login_method", "web_search",
        "tools", "profile", "instructions", "developer_instructions",
        "compact_prompt", "model_reasoning_effort", "model_reasoning_summary",
        "model_verbosity", "service_tier", "analytics", "apps", "desktop",
    ]

    /// `ConfigToml` top-level keys whose serde shape is NOT a plain
    /// always-null `Option`, so the projection must NOT force them to `.null`
    /// when unset. Two groups:
    ///   1. `HashMap` fields (`#[serde(default)]` over a map) → always serialize
    ///      as `{}` even when empty (config_toml.rs `mcp_servers`,
    ///      `model_providers`, `profiles`, `plugins`, `marketplaces`).
    ///   2. `Option` fields carrying a NON-None `#[serde(default = "...")]`, so
    ///      `ConfigToml::default()` serializes a concrete value rather than null
    ///      (`allow_login_shell`, `project_doc_max_bytes`,
    ///      `project_doc_fallback_filenames`, `history`, `hide_agent_reasoning`).
    /// Plus `shell_environment_policy` (a `#[serde(default)]` STRUCT, never an
    /// `Option`) and `features` (codex-swift injects a concrete object).
    /// Everything in `configTomlTopLevelKeys` NOT in this set is a plain
    /// `Option` and therefore serializes as explicit `null` when unset.
    static let configTomlNonNullDefaultKeys: Set<String> = [
        // HashMaps → `{}`
        "mcp_servers", "model_providers", "profiles", "plugins", "marketplaces",
        // Option with non-None serde default
        "allow_login_shell", "project_doc_max_bytes",
        "project_doc_fallback_filenames", "history", "hide_agent_reasoning",
        // default struct + injected object
        "shell_environment_policy", "features",
    ]

    /// Project the deep-merged TOML map onto upstream's typed v2 `Config`
    /// wire shape, mirroring the two-step
    /// `effective.try_into::<ConfigToml>()` → `serde_json::from_value::<Config>()`
    /// round-trip in `config_manager_service.rs:127-139`:
    ///
    ///   1. Drop any top-level key that is not a `ConfigToml` field — these are
    ///      silently lost during `try_into::<ConfigToml>()` (no top-level
    ///      flatten catch-all on `ConfigToml`).
    ///   2. Ensure every NAMED v2 `Config` field is present: emit its merged
    ///      value, or an explicit `.null` when unset (no `skip_serializing_if`).
    ///      `profiles` uses `#[serde(default)]` over a `HashMap`, so it defaults
    ///      to an empty object `{}` rather than `null`.
    ///   3. Surviving non-v2 `ConfigToml` keys pass through (the `additional`
    ///      flatten in v2 `Config`).
    public func configProjectionJSON() -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        // Step 1 + 3: keep only ConfigToml-known top-level keys.
        for (k, v) in merged where Config.configTomlTopLevelKeys.contains(k) {
            out[k] = v
        }
        // Legacy `tools.web_search = bool` collapse: upstream
        // `deserialize_optional_web_search_tool_config` (config_toml.rs:648-679)
        // maps the boolean `WebSearchToolConfigInput::Enabled` form to `None`,
        // so only the table form survives. `ToolsToml.web_search` is an
        // `Option` with no skip_serializing_if, so on a present `tools` table it
        // serializes the dropped value as `null`.
        if case .object(var tools)? = out["tools"] {
            if case .bool? = tools["web_search"] {
                tools["web_search"] = .null
                out["tools"] = .object(tools)
            }
        }
        // Step 2: every v2 named field is present, null when unset.
        for field in Config.v2ConfigNamedFields where out[field] == nil {
            out[field] = .null
        }
        // Step 2b: upstream serializes the ENTIRE effective `ConfigToml` with no
        // container-level skip_serializing_if (config_manager_service.rs:
        // 129-137), so every top-level `Option` field that lacks a non-None
        // serde default is emitted as explicit `null` when unset and flows into
        // `Config.additional`. Emit those here too so a minimal config's
        // `config/read.config` carries the same key set upstream does.
        for field in Config.configTomlTopLevelKeys
        where out[field] == nil
            && !Config.configTomlNonNullDefaultKeys.contains(field) {
            out[field] = .null
        }
        // `profiles` is `#[serde(default)] HashMap` on v2 Config: empty object,
        // never null.
        if out["profiles"] == nil { out["profiles"] = .object([:]) }
        return out
    }
    /// Upstream `config/read` `origins`: `HashMap<dottedLeafPath,
    /// ConfigLayerMetadata>` where each value is `{ name: ConfigLayerSource,
    /// version }`.
    public func originsJSON() -> [String: ConfigValue] {
        var o: [String: ConfigValue] = [:]
        for (k, meta) in leafOrigins { o[k] = meta.toJSON() }
        return o
    }
}

public enum ConfigError: Error, Sendable { case io(String) }

/// Loads the on-disk config and composes the layer stack. The precedence
/// (lowest → highest) matches upstream codex (`config/src/loader/mod.rs`):
///   defaults < system (`/etc/codex/config.toml`) < user (`$CODEX_HOME/config.toml`,
///     + inline `[profiles.<name>]` overlay) < profile-v2 (`$CODEX_HOME/<name>.config.toml`,
///     when selected) < project-local (`.codex/config.toml` walked from cwd up to a
///     repo-root marker — lowest dir wins) < `CODEX_CFG_*` env < explicit
///     overrides (CLI `--config`, runtime).
///
/// Upstream codex uses TOML exclusively — any legacy `config.json` is migrated
/// into `config.toml` on first load (one-shot, non-destructive: `config.json`
/// is left alone so older builds keep working until they're retired).
public struct ConfigLoader: Sendable {
    public let codexHome: String
    /// Override for `/etc/codex/config.toml` (so tests can point at a tmp
    /// path). Production callers pass `nil` and the loader uses the canonical
    /// Unix system path.
    public let systemConfigPath: String?
    /// Override for the legacy `/etc/codex/managed_config.toml` file layer (so
    /// tests can point at a tmp path). Production callers pass `nil` and the
    /// loader uses the canonical Unix path. Upstream
    /// `CODEX_MANAGED_CONFIG_SYSTEM_PATH` (config/src/loader/layer_io.rs:19).
    public let legacyManagedConfigPath: String?
    /// Starting directory for project-local config discovery (cwd → first
    /// ancestor with `.git`). When `nil`, the project-local layer is skipped
    /// entirely — this matches upstream's `load_config_layers_state(.., cwd:
    /// None, ..)` for thread-agnostic loads (e.g. the app server `/config`
    /// endpoint). Pass an explicit path to enable discovery (codexd does
    /// this against the supervisor's working directory).
    public let cwdOverride: String?

    /// macOS managed-preferences (MDM) application domain that admins push
    /// `config_toml_base64` through. Upstream `MANAGED_PREFERENCES_APPLICATION_ID`
    /// (`config/src/loader/macos.rs:22`).
    public let managedPreferenceDomain: String
    /// macOS managed-preferences key holding the base64-encoded `config.toml`
    /// delivered by MDM. Upstream `MANAGED_PREFERENCES_CONFIG_KEY`
    /// (`config/src/loader/macos.rs:23`).
    public let managedPreferenceKey: String
    /// Test seam: when set, this base64 string is used in place of reading the
    /// live managed-preferences domain (so the MDM layer can be exercised
    /// off-device / on non-macOS). `nil` means "read the live domain on macOS".
    public let managedConfigBase64Override: String?

    public init(codexHome: String,
                systemConfigPath: String? = nil,
                cwdOverride: String? = nil,
                legacyManagedConfigPath: String? = nil,
                managedPreferenceDomain: String = "com.openai.codex",
                managedPreferenceKey: String = "config_toml_base64",
                managedConfigBase64Override: String? = nil) {
        self.codexHome = codexHome
        self.systemConfigPath = systemConfigPath
        self.cwdOverride = cwdOverride
        self.legacyManagedConfigPath = legacyManagedConfigPath
        self.managedPreferenceDomain = managedPreferenceDomain
        self.managedPreferenceKey = managedPreferenceKey
        self.managedConfigBase64Override = managedConfigBase64Override
    }

    /// Legacy `config.json` path (codex-swift only — upstream has no JSON
    /// layer). Retained so the loader can perform a one-shot migration into
    /// the canonical TOML file when it's present on disk.
    public var legacyJSONPath: String { codexHome + "/config.json" }
    public var tomlPath: String { codexHome + "/config.toml" }

    /// Canonical Unix system config path (upstream `SYSTEM_CONFIG_TOML_FILE_UNIX`).
    public static let defaultSystemConfigPath = "/etc/codex/config.toml"
    /// Effective system config path (honoring the per-loader override).
    public var effectiveSystemConfigPath: String {
        systemConfigPath ?? ConfigLoader.defaultSystemConfigPath
    }

    /// Canonical Unix legacy managed-config path (upstream
    /// `CODEX_MANAGED_CONFIG_SYSTEM_PATH`, loader/layer_io.rs:19).
    public static let defaultLegacyManagedConfigPath = "/etc/codex/managed_config.toml"
    /// Effective legacy managed-config path (honoring the per-loader override).
    public var effectiveLegacyManagedConfigPath: String {
        legacyManagedConfigPath ?? ConfigLoader.defaultLegacyManagedConfigPath
    }

    /// Suffix for profile-v2 files: `$CODEX_HOME/<name>.config.toml`
    /// (upstream `CONFIG_PROFILE_V2_SUFFIX`).
    public static let profileV2Suffix = ".config.toml"
    /// Build the `$CODEX_HOME/<name>.config.toml` path for a profile-v2 name.
    public func profileV2Path(_ name: String) -> String {
        codexHome + "/" + name + ConfigLoader.profileV2Suffix
    }

    /// Validate a profile-v2 name, mirroring upstream's `ProfileV2Name`
    /// newtype whose only constructor (`FromStr`,
    /// protocol/src/config_types.rs:110-126) rejects empty names and any name
    /// containing a byte other than ASCII-alphanumeric / `_` / `-`. This is a
    /// SECURITY guard: an unvalidated name (e.g. `../../etc/cron.d/x`) would
    /// otherwise escape `$CODEX_HOME` when passed to `profileV2Path`. Upstream
    /// never lets an invalid name reach the path builder because the loader
    /// only ever receives an already-validated `Option<ProfileV2Name>`.
    public static func validateProfileV2Name(_ value: String) -> Bool {
        if value.isEmpty { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            // ASCII alphanumeric or `_` / `-` (matches Rust
            // `is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')`).
            (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar == "_" || scalar == "-"
        }
    }

    /// Upstream's parse-error display for an invalid profile-v2 name
    /// (protocol/src/config_types.rs, `ProfileV2NameParseError` Display).
    static func invalidProfileV2NameMessage(_ value: String) -> String {
        "invalid --profile-v2 value `\(value)`; pass a plain name such as `work`"
    }

    /// Reserved built-in model-provider IDs that a user `model_providers` table
    /// may NOT override, mirroring upstream `RESERVED_MODEL_PROVIDER_IDS`
    /// (config/src/config_toml.rs:63-68). `amazon-bedrock` is special-cased
    /// (allowed) by `validate_reserved_model_provider_ids` (config_toml.rs:939).
    static let reservedModelProviderIDs: Set<String> =
        ["amazon-bedrock", "openai", "ollama", "lmstudio"]
    static let amazonBedrockProviderID = "amazon-bedrock"

    /// Validate `forced_chatgpt_workspace_id` and `model_providers` over the
    /// merged config, returning upstream's verbatim error message on the first
    /// failure (or `nil` when valid). Mirrors the deserialize-time guards in
    /// `config/src/config_toml.rs` (the custom `Deserialize for
    /// ForcedChatgptWorkspaceIds` at :116-139 and `validate_model_providers` /
    /// `validate_reserved_model_provider_ids` at :933-990). The Swift loader
    /// parses TOML into a generic `ConfigValue` tree with no per-key value
    /// checks, so these gates are applied post-merge here (and at write time).
    static func validateMergedConfig(_ merged: [String: ConfigValue]) -> String? {
        // forced_chatgpt_workspace_id: a single string containing a comma is a
        // common mis-encoding of a list and is rejected upstream.
        if case .string(let value)? = merged["forced_chatgpt_workspace_id"],
           value.contains(",") {
            return "forced_chatgpt_workspace_id must be a single workspace ID "
                + "string or a TOML list of strings; comma-separated strings "
                + "are not supported. Use `forced_chatgpt_workspace_id = "
                + "[\"123e4567-e89b-42d3-a456-426614174000\", "
                + "\"123e4567-e89b-42d3-a456-426614174001\"]` instead."
        }
        // model_providers: reject reserved built-in IDs and empty names.
        if case .object(let providers)? = merged["model_providers"] {
            var conflicts: [String] = []
            for key in providers.keys
            where key != amazonBedrockProviderID
                && reservedModelProviderIDs.contains(key) {
                conflicts.append("`\(key)`")
            }
            conflicts.sort()
            if !conflicts.isEmpty {
                return "model_providers contains reserved built-in provider "
                    + "IDs: \(conflicts.joined(separator: ", ")). Built-in "
                    + "providers cannot be overridden. Rename your custom "
                    + "provider (for example, `openai-custom`)."
            }
            // Empty-name check (validate_model_providers, config_toml.rs:967-971);
            // amazon-bedrock is skipped (its name is built-in).
            let sortedKeys = providers.keys.sorted()
            for key in sortedKeys where key != amazonBedrockProviderID {
                if case .object(let entry) = providers[key],
                   case .string(let name)? = entry["name"],
                   name.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "model_providers.\(key): provider name must not be empty"
                }
            }
        }
        return nil
    }

    /// Keys that may NOT be set from the project-local `.codex/config.toml`
    /// layer ONLY. Project-local config comes from repository contents, so a
    /// cloned/compromised repo must not get to redirect credentials, rewire
    /// model providers, or run arbitrary notify commands. These same settings
    /// ARE still honored from the user, system, managed, and runtime layers —
    /// system configs are administrator-controlled trusted admin settings and
    /// are deliberately NOT filtered (see upstream `loader/mod.rs:57-60`). This
    /// mirrors upstream's `PROJECT_LOCAL_CONFIG_DENYLIST` and the fact that
    /// `sanitize_project_config` is invoked only for project layers
    /// (`loader/mod.rs:1203`).
    /// Ordered to match upstream `PROJECT_LOCAL_CONFIG_DENYLIST`
    /// (loader/mod.rs:61-72) DECLARATION order. `sanitize_project_config`
    /// (loader/mod.rs:877-889) pushes ignored keys in this slice order (NOT
    /// sorted), and `project_ignored_config_keys_warning` joins them in that
    /// order — so the `configWarning.summary` key list must preserve it.
    static let projectLocalConfigDenylist: [String] = [
        "openai_base_url",
        "chatgpt_base_url",
        "apps_mcp_product_sku",
        "model_provider",
        "model_providers",
        "notify",
        "profile",
        "profiles",
        "experimental_realtime_ws_base_url",
        "otel",
    ]

    /// Additional CodexKit-only project-local restrictions for extension
    /// config that can redirect authenticated memory traffic. User, system,
    /// managed, env, and runtime layers still own these settings.
    static let projectLocalNestedConfigDenylist: [String] = [
        "memory.mem0",
        "memory.embeddings_url",
        "memory.embeddings_api_key",
    ]

    /// Canonical key aliasing (codex `config/key_aliases.rs` analog): the
    /// env-derived key is lowercased, so map common lowercase/camel forms
    /// onto the canonical snake_case config keys (matching upstream's TOML
    /// serde naming).
    static let keyAliases: [String: String] = [
        "approvalpolicy": "approval_policy",
        "approval_policy": "approval_policy",
        "sandboxmode": "sandbox_mode",
        "sandbox_mode": "sandbox_mode",
        "model": "model",
        "features": "features",
    ]

    /// One-shot rewrite of legacy JSON keys: drop the schemaVersion marker
    /// and fold legacy top-level feature toggles into the nested `features`
    /// table. Snake_case top-level keys are the canonical wire form
    /// (matching upstream TOML), so they pass through unchanged; any
    /// camelCase residue (`approvalPolicy`, `sandboxMode`) is folded onto
    /// its snake_case counterpart so migrated configs use a single naming
    /// convention.
    static func canonicalizeLegacyJSON(_ d: [String: ConfigValue]) -> [String: ConfigValue] {
        var x = d
        x["__schemaVersion"] = nil
        if let v = x["approvalPolicy"] {
            x["approval_policy"] = x["approval_policy"] ?? v
            x["approvalPolicy"] = nil
        }
        if let v = x["sandboxMode"] {
            x["sandbox_mode"] = x["sandbox_mode"] ?? v
            x["sandboxMode"] = nil
        }
        var feats = x["features"]?.objectValue ?? [:]
        for legacy in ["multiAgentV2", "networkProxy"] where x[legacy] != nil {
            if feats[legacy] == nil { feats[legacy] = x[legacy] }
            x[legacy] = nil
        }
        if !feats.isEmpty { x["features"] = .object(feats) }
        return x
    }

    /// Built-in defaults layer. Emitted in snake_case to match upstream's
    /// `config_toml.rs` wire shape — this is what surfaces via `config/read`,
    /// so it must match what the Rust CLI emits. Each entry has a matching
    /// `default_*` helper in upstream's `config_toml.rs` (see e.g.
    /// `default_allow_login_shell`, `default_history`, etc.).
    private func defaults() -> [String: ConfigValue] {
        // NOTE: `model`, `approval_policy`, and `sandbox_mode` are deliberately
        // NOT defaulted here. Upstream `ConfigToml` declares them as plain
        // `Option` with no serde default, so `config/read.config` surfaces them
        // as absent/null until the user/profile sets them. The effective
        // runtime defaults (model → "gpt-5.5", sandbox → workspace-write,
        // approval → on-request) are applied at resolution time
        // (RequestRouter thread/start + the *Fallback helpers), not baked into
        // the serialized config surface.
        [
            "features": .object([:]),
            "allow_login_shell": .bool(true),
            // History::default() serializes via serde(default) — persistence
            // defaults to "save-all" (HistoryPersistence::SaveAll) and
            // max_bytes is an `Option<usize>` with no skip_serializing_if, so
            // `History::default()` always serializes `max_bytes: null`
            // (config/src/types.rs:163-173).
            "history": .object([
                "persistence": .string("save-all"),
                "max_bytes": .null,
            ]),
            "project_doc_max_bytes": .int(Config.defaultProjectDocMaxBytes),
            "project_doc_fallback_filenames": .array([]),
            "hide_agent_reasoning": .bool(false),
            // Always-present `ConfigToml` maps/structs that carry no
            // skip_serializing_if, so `try_into::<ConfigToml>()` + serialize
            // always emits them even when empty
            // (config_toml.rs:251/274/434/438 HashMaps, :172
            // ShellEnvironmentPolicyToml). They flow through v2
            // Config.additional (config.rs:283-284), so `config/read` must show
            // them for an empty/minimal config.
            "mcp_servers": .object([:]),
            "model_providers": .object([:]),
            "plugins": .object([:]),
            "marketplaces": .object([:]),
            // ShellEnvironmentPolicyToml::default(): every field is an
            // `Option` with no skip_serializing_if, so the default serializes
            // as all-null (config/src/types.rs:899-912).
            "shell_environment_policy": .object([
                "inherit": .null,
                "ignore_default_excludes": .null,
                "exclude": .null,
                "set": .null,
                "include_only": .null,
                "experimental_use_profile": .null,
            ]),
        ]
    }

    /// CODEX-SWIFT-ONLY EXTENSION (no upstream analog). Upstream's loader has no
    /// env-var-driven config overlay — its only session-precedence layer is
    /// `ConfigLayerSource::SessionFlags` populated from CLI `-c`/`--config`
    /// overrides (loader/mod.rs:321-327). This `CODEX_CFG_*` env layer is a
    /// deliberate codex-swift operator/development convenience: it parses
    /// `CODEX_CFG_<DOTTED__KEY>=value` env vars into a SessionFlags-precedence
    /// layer. It does NOT affect the JSON-RPC wire contract a frontend depends
    /// on (frontends use `-c`/`--config` flags, not env), so the `config/read`
    /// response shape stays faithful when these env vars are unset. See the
    /// audit-findings "config" Finding 5 (intentional divergence). The double
    /// underscore `__` denotes a nested key separator (`A__B` → `a.b`).
    private func envLayer(_ env: [String: String]) -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for (k, v) in env where k.hasPrefix("CODEX_CFG_") {
            let key = String(k.dropFirst("CODEX_CFG_".count))
                .lowercased()
                .replacingOccurrences(of: "__", with: ".")
            var parts = key.split(separator: ".").map(String.init)
            guard let rawTop = parts.first else { continue }
            let canonicalTop = ConfigLoader.keyAliases[rawTop] ?? rawTop
            parts[0] = canonicalTop
            let leaf: ConfigValue = Int64(v).map(ConfigValue.int)
                ?? (["true", "false"].contains(v.lowercased())
                    ? .bool(v.lowercased() == "true") : .string(v))
            func nest(_ ps: ArraySlice<String>) -> ConfigValue {
                guard let h = ps.first else { return leaf }
                return .object([h: nest(ps.dropFirst())])
            }
            if parts.count == 1 {
                out[canonicalTop] = Config.deepMerge(out[canonicalTop], leaf)
            } else {
                let branch = nest(parts.dropFirst()[...])
                out[canonicalTop] = Config.deepMerge(
                    out[canonicalTop], .object([parts[1]: branch.objectValue?[parts[1]] ?? branch]))
            }
        }
        return out
    }

    // MARK: codex key-alias normalization (key_aliases.rs)

    /// Path-scoped legacy→canonical rewrite. The only alias codex defines is
    /// in the `[memories]` table: `no_memories_if_mcp_or_web_search` →
    /// `disable_on_external_context` (insert canonical if absent, drop legacy).
    static func normalizeKeyAliases(path: [String],
                                    _ table: inout [String: ConfigValue]) {
        if path == ["memories"] {
            if table["disable_on_external_context"] == nil,
               let legacy = table["no_memories_if_mcp_or_web_search"] {
                table["disable_on_external_context"] = legacy
            }
            table["no_memories_if_mcp_or_web_search"] = nil
        }
    }

    /// Recursively apply `normalizeKeyAliases` over a value tree.
    static func normalizedWithAliases(_ value: ConfigValue,
                                      path: [String]) -> ConfigValue {
        switch value {
        case .object(let o):
            var d = o
            normalizeKeyAliases(path: path, &d)
            var out: [String: ConfigValue] = [:]
            for (k, v) in d {
                out[k] = normalizedWithAliases(v, path: path + [k])
            }
            return .object(out)
        case .array(let a):
            return .array(a.map { normalizedWithAliases($0, path: path) })
        default:
            return value
        }
    }

    // MARK: codex deep-merge (merge.rs merge_toml_values)

    /// Deep-merge `overlay` into `base` (overlay wins). Tables merge
    /// recursively; non-table overlay values replace. Key aliases are
    /// normalized per-table-path on both sides at each level.
    static func mergeOverlay(_ base: inout [String: ConfigValue],
                             _ overlay: [String: ConfigValue],
                             path: [String]) {
        normalizeKeyAliases(path: path, &base)
        var ov = overlay
        normalizeKeyAliases(path: path, &ov)
        for (k, v) in ov {
            if case .object(let ovObj) = v {
                if case .object(var baseObj)? = base[k] {
                    mergeOverlay(&baseObj, ovObj, path: path + [k])
                    base[k] = .object(baseObj)
                } else {
                    var fresh: [String: ConfigValue] = [:]
                    mergeOverlay(&fresh, ovObj, path: path + [k])
                    base[k] = .object(fresh)
                }
            } else {
                base[k] = v
            }
        }
    }

    /// Read the canonical `config.toml` (after one-shot migration of any
    /// legacy `config.json`) and return the raw root table.
    func loadTOMLRoot() -> [String: ConfigValue] {
        var rootFromTOML: [String: ConfigValue] = [:]
        if let data = FileManager.default.contents(atPath: tomlPath),
           let text = String(data: data, encoding: .utf8) {
            rootFromTOML = (try? TOML.parse(text)) ?? [:]
        }
        // One-shot migration: if a legacy config.json exists, merge its keys
        // into the TOML root and persist. The TOML side wins on conflict so
        // an explicit edit to config.toml is never clobbered. config.json is
        // intentionally left on disk (older builds may still read it; we
        // don't delete user data).
        if let data = FileManager.default.contents(atPath: legacyJSONPath),
           let decoded = try? JSONDecoder().decode([String: ConfigValue].self, from: data) {
            let canonical = ConfigLoader.canonicalizeLegacyJSON(decoded)
            var merged = canonical
            ConfigLoader.mergeOverlay(&merged, rootFromTOML, path: [])
            if merged != rootFromTOML {
                try? persistTOML(merged)
            }
            rootFromTOML = merged
        }
        return rootFromTOML
    }

    /// Read an arbitrary TOML file as a root table. Returns `[:]` if the
    /// file is absent or empty/invalid (matching upstream's "treat missing
    /// as empty table" behavior).
    static func readTOMLFile(_ path: String) -> [String: ConfigValue] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        return (try? TOML.parse(text)) ?? [:]
    }

    /// Drop denied keys from a config tree in place. Used ONLY for the
    /// project-local layer, which is derived from repository contents and must
    /// not be allowed to redirect credentials or rewire model providers. The
    /// system layer is trusted (administrator-controlled) and is never filtered.
    /// Returns the keys that were actually present and removed, sorted, so the
    /// loader can surface a `configWarning` listing the ignored keys
    /// (upstream `sanitize_project_config` → `project_ignored_config_keys`,
    /// loader/mod.rs:1203-1218).
    @discardableResult
    static func applyDenylist(_ root: inout [String: ConfigValue]) -> [String] {
        var removed: [String] = []
        // Iterate in denylist DECLARATION order and emit the ignored keys in
        // that same order (matching upstream `sanitize_project_config`, which
        // pushes from the ordered slice and does NOT sort).
        for key in projectLocalConfigDenylist where root[key] != nil {
            root[key] = nil
            removed.append(key)
        }
        for nestedKey in projectLocalNestedConfigDenylist {
            let parts = nestedKey.split(separator: ".").map(String.init)
            guard removeNestedKey(parts, from: &root) else { continue }
            removed.append(nestedKey)
        }
        return removed
    }

    private static func removeNestedKey(_ path: [String], from object: inout [String: ConfigValue]) -> Bool {
        guard !path.isEmpty else { return false }
        if path.count == 1 {
            guard object[path[0]] != nil else { return false }
            object[path[0]] = nil
            return true
        }
        let key = path[0]
        guard case .object(var child)? = object[key] else { return false }
        let removed = removeNestedKey(Array(path.dropFirst()), from: &child)
        guard removed else { return false }
        if child.isEmpty {
            object[key] = nil
        } else {
            object[key] = .object(child)
        }
        return true
    }

    // NOTE: there is intentionally NO top-level camelCase→snake_case aliasing
    // for live TOML layers. Upstream `ConfigToml` (config_toml.rs:142-143) has
    // no serde key aliases for `approval_policy`/`sandbox_mode`; the only alias
    // codex defines is the `[memories]` table key handled by
    // `normalizeKeyAliases`. A top-level camelCase key (`approvalPolicy`,
    // `sandboxMode`) is therefore an *unknown* field that `try_into::<ConfigToml>()`
    // silently drops. The single place camelCase is folded onto snake_case is
    // the legacy `config.json` migration (`canonicalizeLegacyJSON`), which
    // matches upstream's one-shot migration shape — NOT live config.toml parsing.

    /// Load `/etc/codex/config.toml` (or the test-override path). The system
    /// layer is trusted (administrator-controlled), so the project-local
    /// denylist is deliberately NOT applied here — upstream honors
    /// model_provider/model_providers/base URLs/notify/profile(s)/otel from the
    /// system layer (`loader/mod.rs:57-60`, `198-212`). Missing → empty.
    func loadSystemLayer() -> [String: ConfigValue] {
        var root = ConfigLoader.readTOMLFile(effectiveSystemConfigPath)
        if case .object(let normed) =
            ConfigLoader.normalizedWithAliases(.object(root), path: []) {
            root = normed
        }
        return root
    }

    /// Load the legacy `/etc/codex/managed_config.toml` file layer (or the
    /// test-override path). This is an administrator-delivered, trusted layer
    /// (like the system layer) so the project-local denylist is NOT applied. It
    /// sits at precedence 40 — above session flags (30) and below the MDM layer
    /// (50). Upstream `ConfigLayerSource::LegacyManagedConfigTomlFromFile`
    /// (loader/mod.rs:342-358, layer_io.rs:19). Missing → empty.
    func loadLegacyManagedConfigLayer() -> [String: ConfigValue] {
        var root = ConfigLoader.readTOMLFile(effectiveLegacyManagedConfigPath)
        if case .object(let normed) =
            ConfigLoader.normalizedWithAliases(.object(root), path: []) {
            root = normed
        }
        return root
    }

    /// Load the macOS MDM-delivered managed config layer
    /// (`config_toml_base64`). Upstream reads the managed-preferences value via
    /// `CFPreferencesCopyAppValue(config_toml_base64, com.openai.codex)`
    /// (`config/src/loader/macos.rs`), base64-decodes it, parses it as TOML, and
    /// pushes it as a `LegacyManagedConfigTomlFromMdm` layer at the TOP of the
    /// stack (highest precedence). Returns `nil` when no managed config is
    /// present (the common case for non-managed installs), invalid base64/UTF-8,
    /// or an empty/invalid TOML table. On non-macOS hosts only the explicit
    /// test override is honored (the OS provides no managed-preferences domain).
    func loadManagedMdmLayer() -> [String: ConfigValue]? {
        let encoded: String?
        if let override = managedConfigBase64Override {
            encoded = override
        } else {
            #if os(macOS)
            encoded = UserDefaults(suiteName: managedPreferenceDomain)?
                .string(forKey: managedPreferenceKey)
            #else
            encoded = nil
            #endif
        }
        guard let encoded,
              !encoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard var root = try? TOML.parse(text), !root.isEmpty else { return nil }
        // Managed configs are administrator-delivered and trusted — like the
        // system layer they are NOT subject to the project-local denylist.
        if case .object(let normed) =
            ConfigLoader.normalizedWithAliases(.object(root), path: []) {
            root = normed
        }
        return root.isEmpty ? nil : root
    }

    /// Upstream default markers (`default_project_root_markers`).
    public static let defaultProjectRootMarkers: [String] = [".git"]

    /// Walk from cwd up to the first ancestor containing one of the configured
    /// project-root markers (upstream `project_root_markers`, defaulting to
    /// `[".git"]`), reading `.codex/config.toml` at each level. Upstream
    /// applies these in increasing precedence from the repo root down to cwd
    /// (so cwd wins). Returns the layers ordered lowest-precedence first.
    /// One discovered project-local layer: its `name`/`values` plus an optional
    /// `disabledReason` set when the directory is not explicitly trusted.
    struct ProjectLayerResult {
        var name: String
        var values: [String: ConfigValue]
        var disabledReason: String?
    }

    /// Normalized trust-map lookup keys for a path (upstream
    /// `normalized_project_trust_keys`, loader/mod.rs:970-983). On Unix the key
    /// is the path verbatim (no lowercasing); we additionally include the
    /// symlink-resolved canonical form when it differs, mirroring upstream's
    /// `[normalized_canonical_path, normalized_path]` ordering.
    static func normalizedProjectTrustKeys(_ path: String) -> [String] {
        let normalizedPath = path
        let canonical = (try? FileManager.default
            .destinationOfSymbolicLink(atPath: path)).flatMap { _ in
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            } ?? URL(fileURLWithPath: path).standardizedFileURL.path
        if normalizedPath == canonical { return [canonical] }
        return [canonical, normalizedPath]
    }

    /// Look up a directory key in the merged `[projects]` trust map, matching
    /// either the exact key or (on Windows, where keys are case-folded) a
    /// case-insensitive match — mirroring upstream `project_trust_for_lookup_key`
    /// (loader/mod.rs:992-1008). On Unix this is an exact match. Returns the
    /// matched (trust_key, trust_level) pair.
    static func projectTrustForLookupKey(_ trust: [String: String],
                                         _ lookupKey: String) -> (String, String)? {
        if let level = trust[lookupKey] { return (lookupKey, level) }
        return nil
    }

    /// Compute the trust decision for a project directory, mirroring upstream
    /// `ProjectTrustContext::decision_for_dir` (loader/mod.rs:783-826): check the
    /// dir's own normalized keys first, then the project-root keys, then the
    /// repo-root keys. Returns the matched trust level (`"trusted"` /
    /// `"untrusted"`) and the trust key the match keyed on; an unmatched dir
    /// gets `trustLevel == nil` (unknown → not trusted).
    static func trustDecisionForDir(
        dir: String, projectRoot: String, repoRoot: String?,
        trust: [String: String]
    ) -> (trustLevel: String?, trustKey: String) {
        for k in normalizedProjectTrustKeys(dir) {
            if let (tk, tl) = projectTrustForLookupKey(trust, k) { return (tl, tk) }
        }
        for k in normalizedProjectTrustKeys(projectRoot) {
            if let (tk, tl) = projectTrustForLookupKey(trust, k) { return (tl, tk) }
        }
        if let repoRoot {
            for k in normalizedProjectTrustKeys(repoRoot) {
                if let (tk, tl) = projectTrustForLookupKey(trust, k) { return (tl, tk) }
            }
        }
        // Unknown → fall back to repo-root key (or project-root) for the
        // disabled-reason message (upstream loader/mod.rs:819-825).
        let fallbackKey = repoRoot.flatMap { normalizedProjectTrustKeys($0).first }
            ?? normalizedProjectTrustKeys(projectRoot).first
            ?? projectRoot
        return (nil, fallbackKey)
    }

    /// Build the `disabled_reason` string for a non-trusted decision, mirroring
    /// upstream `disabled_reason_for_decision` (loader/mod.rs:828-844). Returns
    /// `nil` when the decision is Trusted.
    static func disabledReasonForDecision(
        trustLevel: String?, trustKey: String, userConfigFile: String
    ) -> String? {
        if trustLevel == "trusted" { return nil }
        let gated = "project-local config, hooks, and exec policies"
        if trustLevel == "untrusted" {
            return "\(trustKey) is marked as untrusted in \(userConfigFile). "
                + "To load \(gated), mark it trusted."
        }
        return "To load \(gated), add \(trustKey) as a trusted project in "
            + "\(userConfigFile)."
    }

    /// Resolve the git repo root for trust keying: the closest ancestor of
    /// `start` (a directory) that contains a `.git` entry. Mirrors upstream
    /// `find_git_checkout_root` (loader/mod.rs:1094-1110). Returns `nil` when no
    /// ancestor contains `.git`.
    static func findGitCheckoutRoot(_ start: String) -> String? {
        var dir = start
        while true {
            if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    func loadProjectLocalLayers(env: [String: String], markers: [String],
                                projectsTrust: [String: String] = [:],
                                userConfigFile: String? = nil)
        -> (layers: [ProjectLayerResult],
            warnings: [Config.ConfigWarning]) {
        // When no cwd is supplied, skip project-local discovery (matches
        // upstream `cwd: None` thread-agnostic loads).
        guard let cwd = cwdOverride, !cwd.isEmpty else { return ([], []) }
        let start = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard start.hasPrefix("/") else { return ([], []) }

        let effectiveMarkers = markers.filter { !$0.isEmpty }

        // Replicate upstream `find_project_root` (config/src/loader/mod.rs:
        // 1070-1092): the project root is `cwd` when the marker set is EMPTY,
        // OR when no ancestor of cwd contains any configured marker. Only when
        // a marker matches in some ancestor does the project root become that
        // matched ancestor. A marker matches when a file or directory of that
        // name exists in the ancestor directory.
        let projectRoot: String
        if effectiveMarkers.isEmpty {
            projectRoot = start
        } else {
            var matchedRoot: String? = nil
            var probe = start
            while true {
                var matched = false
                for m in effectiveMarkers {
                    if FileManager.default.fileExists(atPath: probe + "/" + m) {
                        matched = true; break
                    }
                }
                if matched { matchedRoot = probe; break }
                let parent = (probe as NSString).deletingLastPathComponent
                if parent == probe || parent.isEmpty { break }
                probe = parent
            }
            // No marker found in any ancestor → upstream returns `cwd`.
            projectRoot = matchedRoot ?? start
        }

        // Collect ancestors from cwd up to (and including) the resolved
        // project root, mirroring upstream `load_project_layers` (mod.rs:
        // 1134-1147), which walks `cwd.ancestors()` and stops after the
        // ancestor equal to `project_root`.
        var ancestors: [String] = []
        var cur = start
        while true {
            ancestors.append(cur)
            if cur == projectRoot { break }
            let parent = (cur as NSString).deletingLastPathComponent
            if parent == cur || parent.isEmpty { break }
            cur = parent
        }

        // Reverse so the outermost (project root) comes first → lowest
        // precedence; cwd last → highest precedence. Matches upstream
        // `load_project_layers` (lowest-precedence first).
        let ordered = Array(ancestors.reversed())
        let codexHomeNormalized =
            URL(fileURLWithPath: codexHome).standardizedFileURL.path

        // Trust keying context (upstream `project_trust_context`,
        // loader/mod.rs:909-958): `projectRoot` is the marker-resolved root;
        // `repoRoot` is the closest ancestor containing `.git`. Both feed
        // `decision_for_dir` so a `[projects]` entry keyed on either the dir,
        // the project root, or the repo root grants trust.
        let repoRoot = ConfigLoader.findGitCheckoutRoot(start)
        let userFile = userConfigFile ?? (codexHome + "/config.toml")

        var out: [ProjectLayerResult] = []
        var warnings: [Config.ConfigWarning] = []
        for dir in ordered {
            let dotCodex = dir + "/.codex"
            // Skip when the discovered `.codex` folder happens to be
            // `$CODEX_HOME` itself — upstream avoids double-loading the user
            // config when a user runs codex from inside their CODEX_HOME.
            let dotCodexNormalized =
                URL(fileURLWithPath: dotCodex).standardizedFileURL.path
            if dotCodexNormalized == codexHomeNormalized { continue }
            let path = dotCodex + "/config.toml"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            // Trust gating (upstream loader/mod.rs:1162-1163): a project-local
            // layer is HONORED only when its directory (or its project/repo
            // root) is explicitly `trust_level = "trusted"` in the user's
            // `[projects]` map. Untrusted OR unknown dirs are loaded DISABLED
            // (a `disabledReason` is attached and the layer contributes
            // nothing to the effective config).
            let decision = ConfigLoader.trustDecisionForDir(
                dir: dir, projectRoot: projectRoot, repoRoot: repoRoot,
                trust: projectsTrust)
            let disabledReason = ConfigLoader.disabledReasonForDecision(
                trustLevel: decision.trustLevel, trustKey: decision.trustKey,
                userConfigFile: userFile)
            var root = ConfigLoader.readTOMLFile(path)
            // Project-local configs are derived from repository contents and
            // are not allowed to set credential- or transport-sensitive keys.
            // Collect the denylisted keys that were actually present so the
            // client can be warned they were ignored (upstream
            // `project_ignored_config_keys_warning`, loader/mod.rs:1203-1218).
            let ignored = ConfigLoader.applyDenylist(&root)
            // Upstream emits the ignored-keys warning ONLY for non-disabled
            // layers (loader/mod.rs:1213 `if disabled_reason.is_none() && ...`).
            if disabledReason == nil && !ignored.isEmpty {
                warnings.append(Config.ConfigWarning(
                    summary: ConfigLoader.projectIgnoredConfigKeysWarning(
                        configPath: path, ignoredKeys: ignored),
                    details: nil,
                    path: path))
            }
            if case .object(let normed) =
                ConfigLoader.normalizedWithAliases(.object(root), path: []) {
                root = normed
            }
            // A disabled layer is still recorded (so `config/read` can surface
            // it with its `disabledReason`); only non-disabled empty layers are
            // dropped, mirroring upstream which always pushes a project layer
            // entry (even empty) but only contributes trusted ones.
            if root.isEmpty && disabledReason == nil { continue }
            out.append(ProjectLayerResult(name: "project:" + dir, values: root,
                                          disabledReason: disabledReason))
        }
        _ = env  // env is reserved for future env-driven discovery overrides
        return (out, warnings)
    }

    /// Upstream `project_ignored_config_keys_warning` (loader/mod.rs:892-907):
    /// the human-readable summary listing the ignored project-local config
    /// keys and the offending config file path.
    static func projectIgnoredConfigKeysWarning(configPath: String,
                                                ignoredKeys: [String]) -> String {
        let keys = ignoredKeys.joined(separator: ", ")
        return "Ignored unsupported project-local config keys in \(configPath): "
            + "\(keys). If you want these settings to apply, manually set them "
            + "in your user-level config.toml."
    }

    /// Resolve the active profile-v2 selection. CLI overrides win, then env
    /// (`CODEX_PROFILE` matches upstream; `CODEX_CFG_PROFILE` retained as a
    /// codex-swift compatibility alias).
    func resolveProfileV2(env: [String: String],
                          overrides: [String: ConfigValue]) -> String? {
        if let v = overrides["profileV2"]?.stringValue { return v }
        // CODEX-SWIFT-ONLY EXTENSION: upstream selects profile-v2 via
        // `LoaderOverrides.user_config_profile`, never an env var. `CODEX_PROFILE_V2`
        // is a deliberate codex-swift operator convenience (audit Finding 5).
        if let v = env["CODEX_PROFILE_V2"] { return v }
        return nil
    }

    /// If a profile-v2 file exists for `name`, load its contents as a layer.
    /// Returns `nil` when no profile is selected or the file is absent
    /// (mirroring upstream — falls through to inline `[profiles.<name>]`).
    func loadProfileV2Layer(_ name: String?) -> [String: ConfigValue]? {
        guard let name, !name.isEmpty else { return nil }
        // Defense-in-depth: never build a path from an unvalidated name
        // (upstream guarantees `ProfileV2Name` already passed `FromStr`).
        guard ConfigLoader.validateProfileV2Name(name) else { return nil }
        let path = profileV2Path(name)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var root = ConfigLoader.readTOMLFile(path)
        if case .object(let normed) =
            ConfigLoader.normalizedWithAliases(.object(root), path: []) {
            root = normed
        }
        return root.isEmpty ? nil : root
    }

    /// Compose the full layer stack. Layer order (lowest → highest precedence)
    /// matches upstream `config/src/loader/mod.rs`:
    ///
    ///   defaults < system < user (+ inline profile overlay) < profile-v2 <
    ///   project-local (repo-root → cwd) < env < overrides
    public func load(env: [String: String] = ProcessInfo.processInfo.environment,
                     overrides: [String: ConfigValue] = [:]) -> Config {
        // --- system (`/etc/codex/config.toml`, trusted — no denylist) ---
        let systemValues = loadSystemLayer()

        // --- managed (macOS MDM `config_toml_base64`) ---
        // Highest-precedence layer upstream (`LegacyManagedConfigTomlFromMdm`).
        let mdmValues = loadManagedMdmLayer()

        // --- user (`$CODEX_HOME/config.toml`) + inline profile overlay ---
        let toml = loadTOMLRoot()

        // Profile selection: CLI override > env (CODEX_PROFILE/CODEX_CFG_PROFILE)
        // > inline `profile` key in user config. Both env-var names are
        // accepted: upstream uses no env var directly but `CODEX_PROFILE`
        // is the natural alias; `CODEX_CFG_PROFILE` is the codex-swift
        // legacy form. Profile-v2 is selected separately via overrides[
        // "profileV2"] or `CODEX_PROFILE_V2`.
        // NOTE: `env["CODEX_PROFILE"]` / `env["CODEX_CFG_PROFILE"]` are
        // CODEX-SWIFT-ONLY EXTENSIONS (audit Finding 5). Upstream resolves the
        // inline profile from `LoaderOverrides.user_config_profile` or the
        // inline `profile` key only — it has no env-var profile selection. These
        // env reads are a deliberate operator convenience and do not affect the
        // wire contract when unset.
        let inlineProfileName = overrides["profile"]?.stringValue
            ?? env["CODEX_PROFILE"]
            ?? env["CODEX_CFG_PROFILE"]
            ?? toml["profile"]?.stringValue
        // The BASE user layer is loaded RAW — matching upstream
        // `load_user_config_layer` (config/src/loader/mod.rs:386-414), which is
        // called with `profile = None` and does NOT strip `[profiles]` nor fold
        // any inline `[profiles.<name>]` overlay into the base layer. The
        // config-layer / `effective_config()` view therefore retains the user's
        // full `[profiles]` map and is NOT profile-overlaid (so `config/read`
        // surfaces `config.profiles` and `config.model` reflects the un-overlaid
        // base). Profile RESOLUTION is a separate step (below): the selected
        // inline `[profiles.<name>]` table is captured into `profileOverlay` and
        // applied ONLY at thread/session resolution time — never folded into the
        // base layer.
        var userValues: [String: ConfigValue] = [:]
        var resolvedProfile: String? = nil
        var profileOverlay: [String: ConfigValue] = [:]
        if !toml.isEmpty {
            var values = toml
            // Capture the selected inline profile table for SESSION-TIME
            // resolution only (do NOT merge it into `values`, and KEEP the
            // `[profiles]` table in the base layer).
            if let name = inlineProfileName,
               case .object(let profiles)? = toml["profiles"],
               case .object(let profileTable)? = profiles[name] {
                resolvedProfile = name
                if case .object(let normedOverlay) =
                    ConfigLoader.normalizedWithAliases(.object(profileTable), path: []) {
                    profileOverlay = normedOverlay
                } else {
                    profileOverlay = profileTable
                }
            }
            if case .object(let normed) =
                ConfigLoader.normalizedWithAliases(.object(values), path: []) {
                values = normed
            }
            userValues = values
        }

        // --- profile-v2 (separate `$CODEX_HOME/<name>.config.toml` file) ---
        var profileV2Name = resolveProfileV2(env: env, overrides: overrides)
        var loadError: String? = nil
        // SECURITY: validate the profile-v2 name BEFORE it is ever used to
        // build a file path (mirrors upstream `ProfileV2Name::from_str`,
        // protocol/src/config_types.rs:110-126). An invalid/traversal name is a
        // hard error: surface upstream's verbatim message and DROP the
        // selection so no out-of-`$CODEX_HOME` path is ever constructed.
        if let name = profileV2Name,
           !ConfigLoader.validateProfileV2Name(name) {
            loadError = ConfigLoader.invalidProfileV2NameMessage(name)
            profileV2Name = nil
            if resolvedProfile == name {
                resolvedProfile = nil
                profileOverlay = [:]
            }
        }
        let baseUserFile = codexHome + "/config.toml"
        // Collision check (upstream loader/mod.rs:227-243): a selected profile-v2
        // whose name ALSO exists as a legacy inline `[profiles.<name>]` table in
        // the base user config is a hard error — applying both layers would be
        // ambiguous. Upstream returns `io::ErrorKind::InvalidData`; here we carry
        // the verbatim message out on `Config.loadError` and DROP the profile-v2
        // selection so neither overlay double-applies.
        if let name = profileV2Name,
           case .object(let baseProfiles)? = toml["profiles"],
           baseProfiles[name] != nil {
            let activeUserFile = profileV2Path(name)
            loadError = "--profile-v2 `\(name)` cannot be used while "
                + "\(baseUserFile) contains legacy `[profiles.\(name)]` config; "
                + "move those settings into \(activeUserFile) or remove "
                + "`[profiles.\(name)]`"
            // Refuse to load either overlay for the colliding profile.
            profileV2Name = nil
            if resolvedProfile == name {
                resolvedProfile = nil
                profileOverlay = [:]
            }
        }
        let profileV2Values = loadError == nil ? (loadProfileV2Layer(profileV2Name) ?? [:]) : [:]
        if profileV2Name != nil && !profileV2Values.isEmpty {
            resolvedProfile = profileV2Name
        }

        // --- project-local (`.codex/config.toml`, repo-root → cwd) ---
        // Resolve effective `project_root_markers` from everything composed so
        // far (defaults + system + user/profile-v2). Upstream merges those
        // lower layers (plus the CLI overrides layer) before reading the key
        // — see `config/src/loader/mod.rs` around `project_root_markers_from_config`.
        // Note: env/overrides could legitimately set the markers too, so honor
        // them here. Project-local layers, by construction, are loaded *after*
        // the markers are resolved, so they cannot influence which markers
        // bound their own discovery (matches upstream).
        var preProjectMerged: [String: ConfigValue] = defaults()
        ConfigLoader.mergeOverlay(&preProjectMerged, systemValues, path: [])
        ConfigLoader.mergeOverlay(&preProjectMerged, userValues, path: [])
        ConfigLoader.mergeOverlay(&preProjectMerged, profileV2Values, path: [])
        ConfigLoader.mergeOverlay(&preProjectMerged, envLayer(env), path: [])
        var overrideForMarkers = overrides
        overrideForMarkers["profileV2"] = nil
        ConfigLoader.mergeOverlay(&preProjectMerged, overrideForMarkers, path: [])
        if let mdmValues { ConfigLoader.mergeOverlay(&preProjectMerged, mdmValues, path: []) }
        let effectiveMarkers: [String]
        if case .array(let a)? = preProjectMerged["project_root_markers"] {
            effectiveMarkers = a.compactMap { $0.stringValue }
        } else {
            effectiveMarkers = ConfigLoader.defaultProjectRootMarkers
        }
        // Extract the merged `[projects.<key>].trust_level` map so project-local
        // layers can be trust-gated (upstream `project_trust_context` reads
        // `projects` off the merged lower-layer config, loader/mod.rs:917-926).
        var projectsTrust: [String: String] = [:]
        if case .object(let projects)? = preProjectMerged["projects"] {
            for (key, entry) in projects {
                if case .object(let tbl) = entry,
                   let level = tbl["trust_level"]?.stringValue {
                    projectsTrust[key] = level
                }
            }
        }
        let userConfigFileForTrust = codexHome + "/config.toml"
        let (projectLayers, projectWarnings) =
            loadProjectLocalLayers(env: env, markers: effectiveMarkers,
                                   projectsTrust: projectsTrust,
                                   userConfigFile: userConfigFileForTrust)

        // --- legacy managed config file (`/etc/codex/managed_config.toml`) ---
        // Precedence 40: above session flags, below the MDM layer.
        let legacyManagedValues = loadLegacyManagedConfigLayer()

        // Upstream `ConfigLayerSource` for each layer (synthetic `defaults`
        // gets none — it is not an origin). System/user paths and project
        // `.codex` folders are surfaced so `config/read` origins can name the
        // exact file each leaf came from.
        let systemFile = systemConfigPath ?? "/etc/codex/config.toml"
        let userFile = codexHome + "/config.toml"
        var layers: [ConfigLayer] = [
            ConfigLayer(name: "defaults", values: defaults(), source: nil),
            ConfigLayer(name: "system", values: systemValues,
                        source: .system(file: systemFile)),
            // Base user layer is always `profile: nil` upstream; only the
            // profile-v2 overlay carries the selected profile name.
            ConfigLayer(name: "toml", values: userValues,
                        source: .user(file: userFile, profile: nil)),
        ]
        // The profile-v2 user layer is pushed ONLY when a profile-v2 is actually
        // selected, mirroring upstream's `if active_user_file != base_user_file`
        // guard (loader/mod.rs:251-257). When no profile-v2 is selected the base
        // user file IS the active user file, so upstream pushes a SINGLE user
        // layer; appending an empty `.user(file: userFile, profile: nil)` layer
        // here would emit a phantom duplicate user entry in `config/read?
        // includeLayers=true` (Finding 1). Its source `file` is the actual
        // `$CODEX_HOME/<name>.config.toml` path upstream reports
        // (core/src/config/mod.rs:1420-1428, state.rs:85-93).
        if let profileV2Name {
            layers.append(ConfigLayer(
                name: "profile-v2", values: profileV2Values,
                source: .user(file: profileV2Path(profileV2Name),
                              profile: profileV2Name)))
        }
        for pl in projectLayers {
            // name is "project:<dir>"; the `.codex` folder is <dir>/.codex.
            let dir = String(pl.name.dropFirst("project:".count))
            layers.append(ConfigLayer(name: pl.name, values: pl.values,
                                      source: .project(dotCodexFolder: dir + "/.codex"),
                                      disabledReason: pl.disabledReason))
        }
        layers.append(ConfigLayer(name: "env", values: envLayer(env),
                                  source: .sessionFlags))
        // Strip `profileV2` from the runtime overrides surface: it controls
        // the loader, not a config key the harness should see leak through.
        var runtimeOverrides = overrides
        runtimeOverrides["profileV2"] = nil
        layers.append(ConfigLayer(name: "override", values: runtimeOverrides,
                                  source: .sessionFlags))
        // Legacy managed config FILE layer (precedence 40): sits above session
        // flags and below the MDM layer (loader/mod.rs:342-358). Administrator-
        // delivered and trusted; only present when the file exists.
        if !legacyManagedValues.isEmpty {
            layers.append(ConfigLayer(
                name: "legacyManaged", values: legacyManagedValues,
                source: .legacyManagedConfigTomlFromFile(
                    file: effectiveLegacyManagedConfigPath)))
        }
        // MDM/managed config sits at the TOP of the stack (highest precedence),
        // matching upstream which pushes `LegacyManagedConfigTomlFromMdm` last
        // (`config/src/loader/mod.rs:360-372`). Only present on a managed macOS
        // host (or when a base64 override is supplied for tests).
        if let mdmValues {
            layers.append(ConfigLayer(name: "mdm", values: mdmValues,
                                      source: .legacyManagedConfigTomlFromMdm))
        }
        let config = Config(layers: layers, profileName: resolvedProfile,
                            profileOverlay: profileOverlay,
                            configWarnings: projectWarnings,
                            loadError: loadError)
        // Post-merge value validation (forced_chatgpt_workspace_id /
        // model_providers reserved-ID + empty-name), matching upstream's
        // deserialize-time guards. A pre-existing fatal load error (e.g. the
        // profile-v2 collision/traversal) takes precedence and is preserved.
        if loadError == nil,
           let validationError = ConfigLoader.validateMergedConfig(config.merged) {
            return Config(layers: layers, profileName: resolvedProfile,
                          profileOverlay: profileOverlay,
                          configWarnings: projectWarnings,
                          loadError: validationError)
        }
        return config
    }

    /// Persist a config tree to `$CODEX_HOME/config.toml`. Upstream codex
    /// uses TOML exclusively, so all writes go through this single path
    /// (callers that previously wrote `config.json` now land here).
    public func persist(_ obj: [String: ConfigValue]) throws {
        try persistTOML(obj)
    }

    /// Serialize a config tree to deterministic TOML at `tomlPath`
    /// (backing `config/value/write` / `config/batchWrite`).
    public func persistTOML(_ root: [String: ConfigValue]) throws {
        // Reject writes that violate the same value guards upstream enforces at
        // deserialize time (reserved/empty model_providers, comma-separated
        // forced_chatgpt_workspace_id) so a `config/value/write` cannot persist
        // a config that would later fail to load.
        if let validationError = ConfigLoader.validateMergedConfig(root) {
            throw ConfigError.io(validationError)
        }
        try? FileManager.default.createDirectory(
            atPath: codexHome, withIntermediateDirectories: true)
        let s = TOML.serialize(root)
        try Data(s.utf8).write(to: URL(fileURLWithPath: tomlPath), options: .atomic)
    }
}
