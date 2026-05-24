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

/// One named configuration layer (lowest precedence first).
public struct ConfigLayer: Sendable, Equatable {
    public var name: String
    public var values: [String: ConfigValue]
    public init(name: String, values: [String: ConfigValue]) {
        self.name = name; self.values = values
    }
}

/// Deep-merged, origin-tracked configuration with feature flags. Pure value
/// type; loading/persistence are explicit.
public struct Config: Sendable, Equatable {
    /// Default project-doc cap (upstream `DEFAULT_PROJECT_DOC_MAX_BYTES`
    /// in `config_toml.rs`).
    public static let defaultProjectDocMaxBytes: Int64 = 32 * 1024

    public private(set) var merged: [String: ConfigValue]
    /// Top-level key → name of the layer that last set it (codex `origins`).
    public private(set) var origins: [String: String]
    /// The resolved named profile (codex `[profiles.<name>]`), if any.
    public private(set) var profileName: String?

    public init(layers: [ConfigLayer],
                profileName: String? = nil) {
        var acc: [String: ConfigValue] = [:]
        var orig: [String: String] = [:]
        for layer in layers {
            for (k, v) in layer.values {
                acc[k] = Config.deepMerge(acc[k], v)
                orig[k] = layer.name
            }
        }
        self.merged = acc
        self.origins = orig
        self.profileName = profileName
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

    public func value(_ path: String) -> ConfigValue? {
        var cur: ConfigValue? = nil
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        cur = merged[first]
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
    public var approvalPolicy: String? { string("approval_policy") ?? string("approvalPolicy") }
    public var sandboxMode: String? { string("sandbox_mode") ?? string("sandboxMode") }
    public var feedbackEnabled: Bool { bool("feedback.enabled") ?? true }

    // Mirrors of upstream `ConfigToml` defaults that surface via `config/read`
    // and are consumed by harness/runtime code paths. Each `??` value matches
    // the corresponding `default_*` helper in upstream's `config_toml.rs`.
    public var allowLoginShell: Bool { bool("allow_login_shell") ?? true }
    public var hideAgentReasoning: Bool { bool("hide_agent_reasoning") ?? false }
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
        if case .object(let feats)? = merged["features"],
           let v = feats[name]?.boolValue {
            return v
        }
        return false
    }

    // MARK: wire shape for `config/read`

    public func configObjectJSON() -> [String: ConfigValue] { merged }
    public func originsJSON() -> [String: ConfigValue] {
        var o: [String: ConfigValue] = [:]
        for (k, v) in origins { o[k] = .string(v) }
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
    /// Starting directory for project-local config discovery (cwd → first
    /// ancestor with `.git`). When `nil`, the project-local layer is skipped
    /// entirely — this matches upstream's `load_config_layers_state(.., cwd:
    /// None, ..)` for thread-agnostic loads (e.g. the app server `/config`
    /// endpoint). Pass an explicit path to enable discovery (codexd does
    /// this against the supervisor's working directory).
    public let cwdOverride: String?

    public init(codexHome: String,
                systemConfigPath: String? = nil,
                cwdOverride: String? = nil) {
        self.codexHome = codexHome
        self.systemConfigPath = systemConfigPath
        self.cwdOverride = cwdOverride
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

    /// Suffix for profile-v2 files: `$CODEX_HOME/<name>.config.toml`
    /// (upstream `CONFIG_PROFILE_V2_SUFFIX`).
    public static let profileV2Suffix = ".config.toml"
    /// Build the `$CODEX_HOME/<name>.config.toml` path for a profile-v2 name.
    public func profileV2Path(_ name: String) -> String {
        codexHome + "/" + name + ConfigLoader.profileV2Suffix
    }

    /// Keys that may NOT be set from less-trusted config layers (project-local
    /// `.codex/config.toml` and system `/etc/codex/config.toml`). Project-local
    /// configs live in a repository so they should not get to redirect
    /// credentials or rewire model providers; system configs are
    /// administrator-controlled and should likewise stay out of the
    /// credential/transport business. This mirrors upstream's
    /// `PROJECT_LOCAL_CONFIG_DENYLIST` exactly.
    static let projectLocalConfigDenylist: Set<String> = [
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
        [
            "model": .string("gpt-5.1-codex"),
            "approval_policy": .string("on-request"),
            "sandbox_mode": .string("workspace-write"),
            "features": .object([:]),
            "allow_login_shell": .bool(true),
            // History::default() serializes via serde(default) — persistence
            // defaults to "save-all" (HistoryPersistence::SaveAll), max_bytes
            // remains unset.
            "history": .object(["persistence": .string("save-all")]),
            "project_doc_max_bytes": .int(Config.defaultProjectDocMaxBytes),
            "project_doc_fallback_filenames": .array([]),
            "hide_agent_reasoning": .bool(false),
        ]
    }

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

    /// Drop denied keys from a config tree in place. Used for system and
    /// project-local layers, which must not be allowed to redirect
    /// credentials or rewire model providers.
    static func applyDenylist(_ root: inout [String: ConfigValue]) {
        for key in projectLocalConfigDenylist { root[key] = nil }
    }

    /// Normalize legacy camelCase keys to the canonical snake_case form
    /// used by upstream (`approvalPolicy` → `approval_policy`, `sandboxMode`
    /// → `sandbox_mode`). Without this, a user (or older `config.toml`)
    /// that wrote camelCase would not shadow the snake_case defaults that
    /// match upstream's TOML serde naming.
    static func normalizeTopLevelAliases(_ root: inout [String: ConfigValue]) {
        let camelToSnake: [String: String] = [
            "approvalPolicy": "approval_policy",
            "sandboxMode": "sandbox_mode",
        ]
        for (camel, snake) in camelToSnake {
            if let v = root[camel], root[snake] == nil {
                root[snake] = v
                root[camel] = nil
            }
        }
    }

    /// Load `/etc/codex/config.toml` (or the test-override path) with the
    /// security denylist applied. Missing → empty.
    func loadSystemLayer() -> [String: ConfigValue] {
        var root = ConfigLoader.readTOMLFile(effectiveSystemConfigPath)
        ConfigLoader.applyDenylist(&root)
        ConfigLoader.normalizeTopLevelAliases(&root)
        if case .object(let normed) =
            ConfigLoader.normalizedWithAliases(.object(root), path: []) {
            root = normed
        }
        return root
    }

    /// Upstream default markers (`default_project_root_markers`).
    public static let defaultProjectRootMarkers: [String] = [".git"]

    /// Walk from cwd up to the first ancestor containing one of the configured
    /// project-root markers (upstream `project_root_markers`, defaulting to
    /// `[".git"]`), reading `.codex/config.toml` at each level. Upstream
    /// applies these in increasing precedence from the repo root down to cwd
    /// (so cwd wins). Returns the layers ordered lowest-precedence first.
    func loadProjectLocalLayers(env: [String: String],
                                markers: [String]) -> [(name: String, values: [String: ConfigValue])] {
        // When no cwd is supplied, skip project-local discovery (matches
        // upstream `cwd: None` thread-agnostic loads).
        guard let cwd = cwdOverride, !cwd.isEmpty else { return [] }
        let start = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard start.hasPrefix("/") else { return [] }

        // Empty marker list disables the walk entirely (upstream behavior:
        // `find_project_root` returns None for an empty marker slice).
        let effectiveMarkers = markers.filter { !$0.isEmpty }

        // Collect ancestors from cwd up to the first repo root (or filesystem
        // root). Upstream's `find_project_root` uses the configured
        // `project_root_markers` (defaulting to `.git`) to bound the walk.
        // A marker matches when a file or directory of that name exists in
        // the ancestor directory.
        var ancestors: [String] = []
        var cur = start
        while true {
            ancestors.append(cur)
            var matched = false
            if !effectiveMarkers.isEmpty {
                for m in effectiveMarkers {
                    let p = cur + "/" + m
                    if FileManager.default.fileExists(atPath: p) {
                        matched = true; break
                    }
                }
            }
            if matched { break }
            let parent = (cur as NSString).deletingLastPathComponent
            if parent == cur || parent.isEmpty { break }
            cur = parent
        }

        // Reverse so the outermost (repo root) comes first → lowest
        // precedence; cwd last → highest precedence. Matches upstream
        // `load_project_layers` (lowest-precedence first).
        let ordered = Array(ancestors.reversed())
        let codexHomeNormalized =
            URL(fileURLWithPath: codexHome).standardizedFileURL.path

        var out: [(String, [String: ConfigValue])] = []
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
            var root = ConfigLoader.readTOMLFile(path)
            // Project-local configs are derived from repository contents and
            // are not allowed to set credential- or transport-sensitive keys.
            ConfigLoader.applyDenylist(&root)
            ConfigLoader.normalizeTopLevelAliases(&root)
            if case .object(let normed) =
                ConfigLoader.normalizedWithAliases(.object(root), path: []) {
                root = normed
            }
            if root.isEmpty { continue }
            out.append(("project:" + dir, root))
        }
        _ = env  // env is reserved for future env-driven discovery overrides
        return out
    }

    /// Resolve the active profile-v2 selection. CLI overrides win, then env
    /// (`CODEX_PROFILE` matches upstream; `CODEX_CFG_PROFILE` retained as a
    /// codex-swift compatibility alias).
    func resolveProfileV2(env: [String: String],
                          overrides: [String: ConfigValue]) -> String? {
        if let v = overrides["profileV2"]?.stringValue { return v }
        if let v = env["CODEX_PROFILE_V2"] { return v }
        return nil
    }

    /// If a profile-v2 file exists for `name`, load its contents as a layer.
    /// Returns `nil` when no profile is selected or the file is absent
    /// (mirroring upstream — falls through to inline `[profiles.<name>]`).
    func loadProfileV2Layer(_ name: String?) -> [String: ConfigValue]? {
        guard let name, !name.isEmpty else { return nil }
        let path = profileV2Path(name)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var root = ConfigLoader.readTOMLFile(path)
        ConfigLoader.normalizeTopLevelAliases(&root)
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
        // --- system (`/etc/codex/config.toml`, denylist applied) ---
        let systemValues = loadSystemLayer()

        // --- user (`$CODEX_HOME/config.toml`) + inline profile overlay ---
        let toml = loadTOMLRoot()

        // Profile selection: CLI override > env (CODEX_PROFILE/CODEX_CFG_PROFILE)
        // > inline `profile` key in user config. Both env-var names are
        // accepted: upstream uses no env var directly but `CODEX_PROFILE`
        // is the natural alias; `CODEX_CFG_PROFILE` is the codex-swift
        // legacy form. Profile-v2 is selected separately via overrides[
        // "profileV2"] or `CODEX_PROFILE_V2`.
        let inlineProfileName = overrides["profile"]?.stringValue
            ?? env["CODEX_PROFILE"]
            ?? env["CODEX_CFG_PROFILE"]
            ?? toml["profile"]?.stringValue
        var userValues: [String: ConfigValue] = [:]
        var resolvedProfile: String? = nil
        if !toml.isEmpty {
            var values = toml
            values["profiles"] = nil
            if let name = inlineProfileName,
               case .object(let profiles)? = toml["profiles"],
               case .object(let profileTable)? = profiles[name] {
                ConfigLoader.mergeOverlay(&values, profileTable, path: [])
                resolvedProfile = name
            }
            if case .object(let normed) =
                ConfigLoader.normalizedWithAliases(.object(values), path: []) {
                values = normed
            }
            userValues = values
        }

        // --- profile-v2 (separate `$CODEX_HOME/<name>.config.toml` file) ---
        let profileV2Name = resolveProfileV2(env: env, overrides: overrides)
        let profileV2Values = loadProfileV2Layer(profileV2Name) ?? [:]
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
        let effectiveMarkers: [String]
        if case .array(let a)? = preProjectMerged["project_root_markers"] {
            effectiveMarkers = a.compactMap { $0.stringValue }
        } else {
            effectiveMarkers = ConfigLoader.defaultProjectRootMarkers
        }
        let projectLayers = loadProjectLocalLayers(env: env, markers: effectiveMarkers)

        var layers: [ConfigLayer] = [
            ConfigLayer(name: "defaults", values: defaults()),
            ConfigLayer(name: "system", values: systemValues),
            ConfigLayer(name: "toml", values: userValues),
            ConfigLayer(name: "profile-v2", values: profileV2Values),
        ]
        for (name, values) in projectLayers {
            layers.append(ConfigLayer(name: name, values: values))
        }
        layers.append(ConfigLayer(name: "env", values: envLayer(env)))
        // Strip `profileV2` from the runtime overrides surface: it controls
        // the loader, not a config key the harness should see leak through.
        var runtimeOverrides = overrides
        runtimeOverrides["profileV2"] = nil
        layers.append(ConfigLayer(name: "override", values: runtimeOverrides))
        return Config(layers: layers, profileName: resolvedProfile)
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
        try? FileManager.default.createDirectory(
            atPath: codexHome, withIntermediateDirectories: true)
        let s = TOML.serialize(root)
        try Data(s.utf8).write(to: URL(fileURLWithPath: tomlPath), options: .atomic)
    }
}
