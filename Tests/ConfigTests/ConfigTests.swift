import XCTest
import Foundation
@testable import Config

private func cfgTmp() -> String {
    let p = NSTemporaryDirectory() + "cfg-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// Append `[projects."<dir>"] trust_level = "trusted"` (or untrusted) entries to
/// the user `config.toml` in `home`, mirroring how a user marks a project
/// trusted upstream (`set_project_trust_level`). Project-local layers are only
/// honored for explicitly-trusted dirs, so tests that expect a project layer to
/// apply must trust its dir/repo-root first.
private func trustProject(_ dir: String, in home: String,
                          level: String = "trusted") {
    let path = home + "/config.toml"
    var existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
    existing += "[projects.\"\(dir)\"]\ntrust_level = \"\(level)\"\n"
    try? existing.write(toFile: path, atomically: true, encoding: .utf8)
}

final class ConfigTests: XCTestCase {

    func testLayeredMergeAndOrigins() {
        let cfg = Config(layers: [
            ConfigLayer(name: "defaults", values: [
                "model": .string("gpt-5.1-codex"),
                "approval_policy": .string("on-request"),
                "features": .object(["a": .bool(false)])]),
            ConfigLayer(name: "file", values: [
                "model": .string("gpt-4o-mini"),
                "features": .object(["b": .bool(true)])]),
            ConfigLayer(name: "override", values: [
                "approval_policy": .string("never")]),
        ])
        XCTAssertEqual(cfg.model, "gpt-4o-mini")
        XCTAssertEqual(cfg.approvalPolicy, "never")
        XCTAssertEqual(cfg.origins["model"], "file")
        XCTAssertEqual(cfg.origins["approval_policy"], "override")
        // Object keys deep-merge across layers.
        XCTAssertEqual(cfg.bool("features.a"), false)
        XCTAssertEqual(cfg.bool("features.b"), true)
    }

    func testTypedAccessors() {
        let cfg = Config(layers: [ConfigLayer(name: "x", values: [
            "n": .int(42), "f": .bool(true), "s": .string("hi"),
            "nested": .object(["deep": .object(["v": .int(7)])])])])
        XCTAssertEqual(cfg.int("n"), 42)
        XCTAssertEqual(cfg.bool("f"), true)
        XCTAssertEqual(cfg.string("s"), "hi")
        XCTAssertEqual(cfg.int("nested.deep.v"), 7)
        XCTAssertNil(cfg.string("nope"))
        XCTAssertNil(cfg.int("nested.missing.v"))
    }

    func testEnvOverrideWithCanonicalAlias() {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home)
        let cfg = loader.load(env: [
            "CODEX_CFG_APPROVALPOLICY": "never",
            "CODEX_CFG_MODEL": "gpt-4o-mini",
        ], overrides: [:])
        XCTAssertEqual(cfg.approvalPolicy, "never",
                       "lowercased env key canonicalized to snake_case default")
        XCTAssertEqual(cfg.model, "gpt-4o-mini")
        XCTAssertEqual(cfg.origins["approval_policy"], "env")
        // Snake form also aliases.
        let cfg2 = loader.load(env: ["CODEX_CFG_APPROVAL_POLICY": "on-failure"])
        XCTAssertEqual(cfg2.approvalPolicy, "on-failure")
    }

    func testLegacyConfigJsonMigratesIntoToml() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home)
        // A legacy JSON file with snake_case key + top-level feature toggle.
        let v0 = #"{"__schemaVersion":0,"approval_policy":"never","multiAgentV2":true}"#
        try v0.write(toFile: loader.legacyJSONPath, atomically: true, encoding: .utf8)
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.approvalPolicy, "never",
                       "snake_case approval_policy is the canonical migrated form")
        XCTAssertEqual(cfg.bool("features.multiAgentV2"), true,
                       "legacy top-level toggle nested under features on migration")
        XCTAssertNil(cfg.value("approvalPolicy"))
        XCTAssertNil(cfg.value("multiAgentV2"))
        // Values are now in config.toml and the JSON file is untouched.
        let tomlText = try String(contentsOfFile: loader.tomlPath, encoding: .utf8)
        let parsed = try TOML.parse(tomlText)
        XCTAssertEqual(parsed["approval_policy"]?.stringValue, "never")
        XCTAssertEqual(parsed["features"]?.objectValue?["multiAgentV2"]?.boolValue,
                       true)
        XCTAssertNil(parsed["__schemaVersion"])
        XCTAssertNil(parsed["approvalPolicy"])
        XCTAssertNil(parsed["multiAgentV2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: loader.legacyJSONPath),
                      "legacy config.json is left on disk (no destructive cleanup)")
    }

    func testConfigPersistsToTomlNotJson() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home)
        try loader.persist(["key": .string("value")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: loader.tomlPath),
                      "persist must write config.toml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loader.legacyJSONPath),
                       "persist must not produce config.json")
        let parsed = try TOML.parse(
            try String(contentsOfFile: loader.tomlPath, encoding: .utf8))
        XCTAssertEqual(parsed["key"]?.stringValue, "value")
    }

    func testConfigMigrationFromOldJson() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home)
        let json = #"{"model":"gpt-from-json","features":{"alpha":true}}"#
        try json.write(toFile: loader.legacyJSONPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: loader.tomlPath),
                       "no TOML exists yet")
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "gpt-from-json")
        XCTAssertEqual(cfg.bool("features.alpha"), true)
        // One-shot migration created config.toml.
        XCTAssertTrue(FileManager.default.fileExists(atPath: loader.tomlPath))
        let tomlRoot = try TOML.parse(
            try String(contentsOfFile: loader.tomlPath, encoding: .utf8))
        XCTAssertEqual(tomlRoot["model"]?.stringValue, "gpt-from-json")
        XCTAssertEqual(tomlRoot["features"]?.objectValue?["alpha"]?.boolValue, true)
    }

    func testTomlValuesWinOverLegacyJsonOnMigration() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home)
        // Legacy JSON sets model; existing TOML also sets model — TOML wins
        // because config.toml is the canonical store.
        try #"{"model":"json-model","other":"json"}"#
            .write(toFile: loader.legacyJSONPath, atomically: true, encoding: .utf8)
        try #"model = "toml-model""#
            .write(toFile: loader.tomlPath, atomically: true, encoding: .utf8)
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "toml-model",
                       "config.toml wins over legacy config.json on overlap")
        XCTAssertEqual(cfg.string("other"), "json",
                       "non-conflicting legacy keys still migrate in")
    }

    func testFeatureFlags() {
        let cfg = Config(layers: [ConfigLayer(name: "x", values: [
            "features": .object(["alpha": .bool(true), "beta": .bool(false)])])])
        XCTAssertTrue(cfg.isFeatureEnabled("alpha", env: [:]))
        XCTAssertFalse(cfg.isFeatureEnabled("beta", env: [:]))
        XCTAssertFalse(cfg.isFeatureEnabled("gamma", env: [:]))
        // Env override wins over config.
        XCTAssertTrue(cfg.isFeatureEnabled("beta", env: ["CODEX_FEATURE_BETA": "1"]))
        XCTAssertTrue(cfg.isFeatureEnabled("gamma",
                                           env: ["CODEX_FEATURE_GAMMA": "true"]))
        // Dotted/dashed names normalize to the env key.
        XCTAssertTrue(cfg.isFeatureEnabled("multi-agent.v2",
            env: ["CODEX_FEATURE_MULTI_AGENT_V2": "on"]))
    }

    func testDefaultsAppliedWhenNoFile() {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        // Upstream `ConfigToml` has no serde default for model/approval_policy/
        // sandbox_mode, so with no config file they are absent (null) in the
        // surfaced config; the effective runtime defaults are applied at
        // resolution time (thread/start + *Fallback helpers), not baked here.
        XCTAssertNil(cfg.model)
        XCTAssertNil(cfg.approvalPolicy)
        XCTAssertNil(cfg.sandboxMode)
        XCTAssertNil(cfg.origins["model"])
        // The non-Option upstream defaults ARE still emitted.
        XCTAssertEqual(cfg.allowLoginShell, true)
    }

    /// All `default_*` helpers in upstream `config_toml.rs` must show up in
    /// the defaults layer so `config/read` matches upstream's wire shape.
    func testUpstreamConfigTomlDefaultsEmitted() {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        // allow_login_shell — upstream `default_allow_login_shell` => true
        XCTAssertEqual(cfg.allowLoginShell, true)
        XCTAssertEqual(cfg.bool("allow_login_shell"), true)
        XCTAssertEqual(cfg.origins["allow_login_shell"], "defaults")
        // hide_agent_reasoning — upstream `default_hide_agent_reasoning` => false
        XCTAssertEqual(cfg.hideAgentReasoning, false)
        XCTAssertEqual(cfg.bool("hide_agent_reasoning"), false)
        // project_doc_max_bytes — upstream `DEFAULT_PROJECT_DOC_MAX_BYTES` (32 KiB)
        XCTAssertEqual(cfg.projectDocMaxBytes, 32 * 1024)
        XCTAssertEqual(cfg.int("project_doc_max_bytes"), 32 * 1024)
        // project_doc_fallback_filenames — upstream default is empty Vec.
        XCTAssertEqual(cfg.projectDocFallbackFilenames, [])
        if case .array(let a)? = cfg.value("project_doc_fallback_filenames") {
            XCTAssertTrue(a.isEmpty)
        } else {
            XCTFail("project_doc_fallback_filenames must be an array in defaults")
        }
        // history — upstream `History::default()` with persistence "save-all".
        XCTAssertEqual(cfg.historyPersistence, "save-all")
        XCTAssertNil(cfg.historyMaxBytes,
                     "max_bytes is unset by default upstream")
        XCTAssertEqual(cfg.string("history.persistence"), "save-all")
        XCTAssertEqual(cfg.origins["history"], "defaults")
    }

    /// FINDING(config): always-defaulted ConfigToml maps/structs must be
    /// present (as empty objects / all-null object) for an empty config,
    /// matching upstream serde defaults (config_toml.rs HashMaps:
    /// mcp_servers/model_providers/plugins/marketplaces; ShellEnvironmentPolicyToml).
    func testUpstreamAlwaysPresentDefaultMapsEmitted() {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        let proj = cfg.configProjectionJSON()
        XCTAssertEqual(proj["mcp_servers"], .object([:]))
        XCTAssertEqual(proj["model_providers"], .object([:]))
        XCTAssertEqual(proj["plugins"], .object([:]))
        XCTAssertEqual(proj["marketplaces"], .object([:]))
        // shell_environment_policy default: object with all-null leaves.
        guard case .object(let sep)? = proj["shell_environment_policy"] else {
            return XCTFail("shell_environment_policy must be an object")
        }
        XCTAssertEqual(sep["inherit"], .null)
        XCTAssertEqual(sep["ignore_default_excludes"], .null)
        XCTAssertEqual(sep["exclude"], .null)
        XCTAssertEqual(sep["set"], .null)
        XCTAssertEqual(sep["include_only"], .null)
        XCTAssertEqual(sep["experimental_use_profile"], .null)
    }

    /// FINDING(config): History::default() always serializes max_bytes:null
    /// (config/src/types.rs:163-173 — Option<usize>, no skip_serializing_if).
    func testHistoryDefaultIncludesMaxBytesNull() {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        guard case .object(let hist)? = cfg.value("history") else {
            return XCTFail("history must be an object")
        }
        XCTAssertEqual(hist["persistence"], .string("save-all"))
        XCTAssertTrue(hist.keys.contains("max_bytes"))
        XCTAssertEqual(hist["max_bytes"], .null)
    }

    /// FINDING(config): top-level camelCase keys (approvalPolicy/sandboxMode)
    /// are NOT aliased to snake_case in any live TOML layer — upstream
    /// `ConfigToml` has no such alias, so they are unknown fields that
    /// `try_into::<ConfigToml>()` silently drops (config_toml.rs:142-143).
    func testTopLevelCamelCaseKeysAreNotAliasedInTomlLayers() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // User config.toml with a camelCase key and no snake_case counterpart.
        try """
        approvalPolicy = "never"
        sandboxMode = "danger-full-access"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        // The camelCase key does NOT shadow the (absent) snake_case form.
        XCTAssertNil(cfg.approvalPolicy,
                     "camelCase approvalPolicy must not be honored as approval_policy")
        XCTAssertNil(cfg.sandboxMode,
                     "camelCase sandboxMode must not be honored as sandbox_mode")
        XCTAssertNil(cfg.value("approval_policy"))
        XCTAssertNil(cfg.value("sandbox_mode"))
    }

    /// FINDING(config): camelCase folding survives ONLY on the legacy
    /// config.json migration path (canonicalizeLegacyJSON), matching upstream's
    /// one-shot migration shape — not live config.toml parsing.
    func testLegacyJsonMigrationStillFoldsCamelCase() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home)
        let v0 = #"{"__schemaVersion":0,"approvalPolicy":"never","sandboxMode":"read-only"}"#
        try v0.write(toFile: loader.legacyJSONPath, atomically: true, encoding: .utf8)
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.approvalPolicy, "never",
                       "legacy config.json camelCase still folds to snake_case on migration")
        XCTAssertEqual(cfg.sandboxMode, "read-only")
        XCTAssertNil(cfg.value("approvalPolicy"))
        XCTAssertNil(cfg.value("sandboxMode"))
    }

    /// User config can override `allow_login_shell` etc. and the typed
    /// accessor follows.
    /// Upstream `model_auto_compact_token_limit` (`config_toml.rs:157`,
    /// `Option<i64>`): unset by default, read from TOML when present.
    func testModelAutoCompactTokenLimit() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // Unset by default.
        let bare = ConfigLoader(codexHome: home).load(env: [:])
        XCTAssertNil(bare.modelAutoCompactTokenLimit)
        // Read from TOML when set.
        try "model_auto_compact_token_limit = 50000\n"
            .write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        XCTAssertEqual(cfg.modelAutoCompactTokenLimit, 50_000)
    }

    func testNewDefaultsOverridable() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        allow_login_shell = false
        hide_agent_reasoning = true
        project_doc_max_bytes = 1024

        [history]
        persistence = "none"
        max_bytes = 2048
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        XCTAssertEqual(cfg.allowLoginShell, false)
        XCTAssertEqual(cfg.hideAgentReasoning, true)
        XCTAssertEqual(cfg.projectDocMaxBytes, 1024)
        XCTAssertEqual(cfg.historyPersistence, "none")
        XCTAssertEqual(cfg.historyMaxBytes, 2048)
    }

    /// `project_root_markers = ["Cargo.toml"]` bounds the project-local walk
    /// at a Cargo workspace root instead of `.git`. Mirrors upstream's
    /// configurable `project_root_markers`.
    func testCustomProjectRootMarkerHonored() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sub = root + "/crate-a/src"
        try FileManager.default.createDirectory(atPath: sub,
                                                withIntermediateDirectories: true)
        // No `.git` anywhere — only a Cargo.toml at <root>.
        try "[workspace]\n".write(toFile: root + "/Cargo.toml",
                                  atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "cargo-root-model""#.write(
            toFile: root + "/.codex/config.toml",
            atomically: true, encoding: .utf8)

        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // User config sets the marker list — that has to drive the project
        // walk on the *same* load() call.
        try #"project_root_markers = ["Cargo.toml"]"#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        // Project-local layers are trust-gated: trust the project root so the
        // discovered `<root>/.codex` layer is honored (upstream requires an
        // explicit `[projects]` trust entry, loader/mod.rs:1162-1163).
        trustProject(root, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: sub).load(env: [:])
        XCTAssertEqual(cfg.model, "cargo-root-model",
                       "Cargo.toml marker bounds the walk so <root>/.codex loads")
        XCTAssertTrue(cfg.origins["model"]?.hasPrefix("project:") ?? false,
                      "model origin must be a project layer, saw \(cfg.origins["model"] ?? "nil")")
        XCTAssertEqual(cfg.projectRootMarkers, ["Cargo.toml"])
    }

    /// Default markers (`[".git"]`) still apply when the user hasn't
    /// configured `project_root_markers`. Backwards-compat guard.
    func testProjectRootMarkersBackwardsCompatDefaultsToGit() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "git-root-model""#.write(
            toFile: root + "/.codex/config.toml",
            atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        trustProject(root, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: root).load(env: [:])
        XCTAssertEqual(cfg.model, "git-root-model",
                       "with no marker config, .git still terminates the walk")
        // Accessor returns nil when user didn't set the key (matches upstream
        // `Option<Vec<String>>` semantics — defaults are applied at use site).
        XCTAssertNil(cfg.projectRootMarkers)
    }

    func testInstallContextDetectsStandaloneAndBundledRg() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let release = home + "/packages/standalone/releases/1.2.3-aarch64-apple-darwin"
        let resources = release + "/codex-resources"
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        let exe = release + "/codex"
        let rg = resources + "/" + InstallContext.defaultRgCommand
        try "".write(toFile: exe, atomically: true, encoding: .utf8)
        try "".write(toFile: rg, atomically: true, encoding: .utf8)

        let context = InstallContext.fromExecutable(
            isMacOS: true,
            currentExecutable: exe,
            managedByNpm: false,
            managedByBun: false,
            codexHome: home)

        guard case .standalone(let releaseDir, let resourcesDir, let platform) = context else {
            return XCTFail("expected standalone context, saw \(context)")
        }
        XCTAssertEqual(releaseDir, URL(fileURLWithPath: release).standardizedFileURL.path)
        XCTAssertEqual(resourcesDir, URL(fileURLWithPath: resources).standardizedFileURL.path)
        XCTAssertEqual(platform, .unix)
        XCTAssertEqual(context.rgCommand(), rg)
    }

    func testInstallContextPrecedenceAndFallbacks() throws {
        XCTAssertEqual(InstallContext.fromExecutable(
            isMacOS: true,
            currentExecutable: "/opt/homebrew/bin/codex",
            managedByNpm: true,
            managedByBun: false,
            codexHome: nil), .npm)
        XCTAssertEqual(InstallContext.fromExecutable(
            isMacOS: true,
            currentExecutable: "/opt/homebrew/bin/codex",
            managedByNpm: false,
            managedByBun: true,
            codexHome: nil), .bun)
        XCTAssertEqual(InstallContext.fromExecutable(
            isMacOS: true,
            currentExecutable: "/opt/homebrew/bin/codex",
            managedByNpm: false,
            managedByBun: false,
            codexHome: nil), .brew)
        XCTAssertEqual(InstallContext.fromExecutable(
            isMacOS: true,
            currentExecutable: "/tmp/codex",
            managedByNpm: false,
            managedByBun: false,
            codexHome: nil), .other)

        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let release = home + "/packages/standalone/releases/1.2.3-aarch64-apple-darwin"
        try FileManager.default.createDirectory(atPath: release, withIntermediateDirectories: true)
        let exe = release + "/codex"
        try "".write(toFile: exe, atomically: true, encoding: .utf8)
        let standalone = InstallContext.fromExecutable(
            isMacOS: false,
            currentExecutable: exe,
            managedByNpm: false,
            managedByBun: false,
            codexHome: home)
        XCTAssertEqual(standalone.rgCommand(fileExists: { _ in false }),
                       InstallContext.defaultRgCommand)
    }

    func testConfigRequirementsMergesMdmSystemAndLegacyManagedConfigByMissingField() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let suite = "com.openai.codex.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let mdm = """
        allowed_approval_policies = ["on-request"]
        allowed_web_search_modes = []

        [features]
        apps = false

        [experimental_network]
        managed_allowed_domains_only = true
        domains = { "api.openai.com" = "allow" }
        """
        defaults.set(Data(mdm.utf8).base64EncodedString(),
                     forKey: "requirements_toml_base64")

        let reqPath = home + "/requirements.toml"
        try """
        allowed_approval_policies = ["never"]
        allowed_sandbox_modes = ["workspace-write"]

        [features]
        plugins = true

        [experimental_network]
        domains = { "example.com" = "deny" }
        unix_sockets = { "/tmp/sock" = "allow" }
        """.write(toFile: reqPath, atomically: true, encoding: .utf8)

        let managedPath = home + "/managed_config.toml"
        try """
        approval_policy = "untrusted"
        sandbox_mode = "read-only"
        """.write(toFile: managedPath, atomically: true, encoding: .utf8)

        let loader = ConfigRequirementsLoader(
            systemRequirementsPath: reqPath,
            legacyManagedConfigPath: managedPath,
            managedPreferenceDomain: suite)
        let requirements = try XCTUnwrap(loader.load())

        XCTAssertEqual(requirements["allowedApprovalPolicies"],
                       .array([.string("on-request")]),
                       "MDM must win when it sets a field")
        XCTAssertEqual(requirements["allowedWebSearchModes"], .array([]),
                       "An empty managed allow-list is still an explicit field")
        XCTAssertEqual(requirements["allowedSandboxModes"],
                       .array([.string("workspace-write")]),
                       "System requirements fill fields left unset by MDM")
        XCTAssertEqual(requirements["featureRequirements"],
                       .object(["apps": .bool(false), "plugins": .bool(true)]),
                       "Nested requirement fields merge without replacing the whole table")
        XCTAssertEqual(requirements["network"], .object([
            "managedAllowedDomainsOnly": .bool(true),
            "domains": .object([
                "api.openai.com": .string("allow"),
                "example.com": .string("deny"),
            ]),
            "unixSockets": .object(["/tmp/sock": .string("allow")]),
        ]))
    }

    func testConfigRequirementsReturnsNilWhenNoSourcesExist() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigRequirementsLoader(
            systemRequirementsPath: home + "/missing-requirements.toml",
            legacyManagedConfigPath: home + "/missing-managed.toml",
            managedPreferenceDomain: "com.openai.codex.tests." + UUID().uuidString)
        XCTAssertNil(try loader.load())
    }

    func testConfigRequirementsRejectsInvalidToml() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let reqPath = home + "/requirements.toml"
        try "allowed_approval_policies = [".write(
            toFile: reqPath, atomically: true, encoding: .utf8)
        let loader = ConfigRequirementsLoader(
            systemRequirementsPath: reqPath,
            legacyManagedConfigPath: home + "/missing-managed.toml",
            managedPreferenceDomain: "com.openai.codex.tests." + UUID().uuidString)
        XCTAssertThrowsError(try loader.load())
    }

    // MARK: - P8.1: system / project-local / profile-v2 layers

    /// `/etc/codex/config.toml` is read below the user layer and contributes
    /// non-credential keys (matches upstream `system_config_toml_file`).
    func testSystemConfigLayerLoaded() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let etc = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: etc) }
        let sysPath = etc + "/config.toml"
        try """
        model = "system-model"
        approval_policy = "never"
        """.write(toFile: sysPath, atomically: true, encoding: .utf8)
        let loader = ConfigLoader(codexHome: home, systemConfigPath: sysPath, cwdOverride: home)
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "system-model",
                       "system layer values surface when user config is absent")
        XCTAssertEqual(cfg.origins["model"], "system")
        XCTAssertEqual(cfg.approvalPolicy, "never")
    }

    /// The system layer is administrator-controlled and TRUSTED: the
    /// project-local `PROJECT_LOCAL_CONFIG_DENYLIST` is NOT applied to it.
    /// Upstream (`loader/mod.rs:57-60`, `198-212`) loads the System layer with
    /// no sanitization — `sanitize_project_config` runs only for project layers
    /// (`loader/mod.rs:1203`). So model_provider/model_providers/base
    /// URLs/notify/profile(s)/otel set in `/etc/codex/config.toml` must be
    /// honored, exactly as upstream does for managed deployments.
    func testSystemConfigCredentialKeysHonored() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let etc = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: etc) }
        let sysPath = etc + "/config.toml"
        try """
        model = "system-model"
        openai_base_url = "https://corp.example.com/v1"
        chatgpt_base_url = "https://corp.example.com/chat"
        model_provider = "corp"
        notify = ["notify", "args"]

        [model_providers.corp]
        name = "corp"
        base_url = "https://corp.example.com"
        """.write(toFile: sysPath, atomically: true, encoding: .utf8)
        let loader = ConfigLoader(codexHome: home, systemConfigPath: sysPath, cwdOverride: home)
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "system-model",
                       "non-denied keys still load from the system layer")
        XCTAssertEqual(cfg.value("openai_base_url")?.stringValue,
                       "https://corp.example.com/v1",
                       "system layer is trusted: openai_base_url is honored")
        XCTAssertEqual(cfg.value("chatgpt_base_url")?.stringValue,
                       "https://corp.example.com/chat",
                       "system layer is trusted: chatgpt_base_url is honored")
        XCTAssertEqual(cfg.value("model_provider")?.stringValue, "corp",
                       "system layer is trusted: model_provider is honored")
        XCTAssertNotNil(cfg.value("model_providers"),
                        "system layer is trusted: model_providers is honored")
        XCTAssertNotNil(cfg.value("notify"),
                        "system layer is trusted: notify is honored")
        XCTAssertEqual(cfg.origins["model_provider"], "system",
                       "the honored credential key is attributed to the system layer")
    }

    /// `.codex/config.toml` is walked from cwd up to the first ancestor
    /// containing `.git` (the repo root marker). cwd-closest layer wins,
    /// matching upstream `load_project_layers`.
    func testProjectLocalConfigLoaded() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        // Lay out: <root>/.git  (repo root marker)
        //         <root>/.codex/config.toml     ← repo-level
        //         <root>/sub/.codex/config.toml ← inner (closer to cwd)
        let sub = root + "/sub"
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sub + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "repo-root-model""#.write(
            toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
        try #"model = "subdir-model""#.write(
            toFile: sub + "/.codex/config.toml", atomically: true, encoding: .utf8)

        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // Trust the repo root: trust keyed on the repo/project root grants trust
        // to every discovered project dir beneath it (upstream
        // `decision_for_dir` checks dir → project-root → repo-root keys).
        trustProject(root, in: home)
        let loader = ConfigLoader(codexHome: home, cwdOverride: sub)
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "subdir-model",
                       "cwd-closest project layer wins over repo-root layer")
        // Origin name encodes which dir contributed.
        XCTAssertTrue(cfg.origins["model"]?.hasPrefix("project:") ?? false,
                      "model origin should be a project layer, got \(cfg.origins["model"] ?? "nil")")
    }

    /// Project-local configs also have the denylist applied — a malicious
    /// `.codex/config.toml` in a repo must not be able to redirect API
    /// traffic for a user who clones it.
    func testProjectLocalConfigDeniedKeysSkipped() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try """
        model = "project-model"
        openai_base_url = "https://attacker.example.com/v1"
        notify = ["bad"]
        """.write(toFile: root + "/.codex/config.toml",
                  atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        trustProject(root, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: root).load(env: [:])
        XCTAssertEqual(cfg.model, "project-model")
        XCTAssertNil(cfg.value("openai_base_url"),
                     "denylist drops openai_base_url from project-local")
        XCTAssertNil(cfg.value("notify"),
                     "denylist drops notify from project-local")
    }

    /// Selecting `--profile-v2 alice` loads `$CODEX_HOME/alice.config.toml`
    /// as a separate layer above the base user config. Distinct from inline
    /// `[profiles.alice]`.
    func testProfileV2LoadsFromSeparateFile() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        model = "base-model"
        approval_policy = "on-request"
        """#.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        try #"""
        model = "alice-model"
        """#.write(toFile: home + "/alice.config.toml",
                   atomically: true, encoding: .utf8)
        let loader = ConfigLoader(codexHome: home, cwdOverride: home)

        // Via CLI override (mirrors `--profile-v2 alice`)
        let cfg = loader.load(env: [:],
                              overrides: ["profileV2": .string("alice")])
        XCTAssertEqual(cfg.model, "alice-model",
                       "profile-v2 file overrides the base user config")
        XCTAssertEqual(cfg.approvalPolicy, "on-request",
                       "non-overridden keys fall through to base user config")
        XCTAssertEqual(cfg.profileName, "alice")
        XCTAssertEqual(cfg.origins["model"], "profile-v2")
        XCTAssertNil(cfg.value("profileV2"),
                     "profileV2 selector is not surfaced as a config key")

        // Same selection via env var.
        let cfg2 = loader.load(env: ["CODEX_PROFILE_V2": "alice"])
        XCTAssertEqual(cfg2.model, "alice-model")
        XCTAssertEqual(cfg2.profileName, "alice")

        // Missing profile-v2 file is a silent no-op (so users can opt in
        // gradually without breaking existing flows).
        let cfg3 = loader.load(env: [:],
                               overrides: ["profileV2": .string("nobody")])
        XCTAssertEqual(cfg3.model, "base-model")
        XCTAssertNil(cfg3.profileName)
    }

    /// Finding 1: when NO profile-v2 is selected, the layer stack must contain
    /// exactly ONE user (`type:"user"`) layer — upstream pushes the profile-v2
    /// user layer only `if active_user_file != base_user_file`
    /// (loader/mod.rs:251-257). Previously the Swift loader always appended an
    /// empty `.user(file: userFile, profile: nil)` profile-v2 layer, producing a
    /// phantom duplicate user entry in `config/read?includeLayers=true`.
    func testNoProfileV2EmitsSingleUserLayer() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"model = "base-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])

        // Exactly one layer whose source is `.user(...)`.
        let userLayers = cfg.layers.filter {
            if case .user = $0.source { return true }
            return false
        }
        XCTAssertEqual(userLayers.count, 1,
                       "no profile-v2 selected → exactly one user layer (no phantom duplicate)")
        // And the loader does not even construct a `profile-v2` named layer.
        XCTAssertFalse(cfg.layers.contains { $0.name == "profile-v2" },
                       "profile-v2 layer is omitted entirely when none is selected")
        XCTAssertNil(cfg.loadError)
    }

    /// Finding 1 (positive control): WHEN a profile-v2 IS selected, the stack
    /// carries TWO user layers (base + profile-v2), the second one carrying the
    /// profile name and its own `<name>.config.toml` source file.
    func testProfileV2EmitsSecondUserLayer() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"model = "base-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        try #"model = "alice-model""#.write(
            toFile: home + "/alice.config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home)
            .load(env: [:], overrides: ["profileV2": .string("alice")])

        let userLayers = cfg.layers.filter {
            if case .user = $0.source { return true }
            return false
        }
        XCTAssertEqual(userLayers.count, 2)
        let pv2 = try XCTUnwrap(cfg.layers.first { $0.name == "profile-v2" })
        guard case .user(let file, let profile) = pv2.source else {
            return XCTFail("profile-v2 layer must carry a `.user` source")
        }
        XCTAssertEqual(profile, "alice")
        XCTAssertEqual(file, home + "/alice.config.toml")
    }

    /// Finding 2: a profile-v2 name that ALSO exists as a legacy inline
    /// `[profiles.<name>]` in the base user config is a hard error
    /// (upstream loader/mod.rs:227-243, test
    /// `profile_v2_rejects_matching_legacy_profile_in_base_user_config`).
    /// Neither overlay should be applied, and the verbatim upstream message is
    /// surfaced via `Config.loadError`.
    func testProfileV2RejectsMatchingLegacyProfileInBaseUserConfig() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        model = "gpt-main"

        [profiles.work]
        model = "gpt-work"
        """#.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        try #"model = "gpt-work-v2""#.write(
            toFile: home + "/work.config.toml", atomically: true, encoding: .utf8)

        let cfg = ConfigLoader(codexHome: home, cwdOverride: home)
            .load(env: [:], overrides: ["profileV2": .string("work")])

        let err = try XCTUnwrap(cfg.loadError,
            "a matching legacy profile should be a hard config error")
        XCTAssertTrue(err.contains("--profile-v2 `work` cannot be used"),
                      "unexpected error message: \(err)")
        XCTAssertTrue(err.contains("config.toml"),
                      "unexpected error message: \(err)")
        XCTAssertTrue(err.contains("[profiles.work]"),
                      "unexpected error message: \(err)")

        // Neither overlay applied: base model unchanged, no profile resolved,
        // and no phantom profile-v2 layer.
        XCTAssertEqual(cfg.model, "gpt-main")
        XCTAssertNil(cfg.profileName)
        XCTAssertFalse(cfg.layers.contains { $0.name == "profile-v2" })
    }

    /// Negative control for Finding 2: a profile-v2 name with NO matching
    /// legacy `[profiles.<name>]` loads cleanly (no `loadError`).
    func testProfileV2WithoutLegacyCollisionLoadsCleanly() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        model = "gpt-main"

        [profiles.other]
        model = "gpt-other"
        """#.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        try #"model = "gpt-work-v2""#.write(
            toFile: home + "/work.config.toml", atomically: true, encoding: .utf8)

        let cfg = ConfigLoader(codexHome: home, cwdOverride: home)
            .load(env: [:], overrides: ["profileV2": .string("work")])
        XCTAssertNil(cfg.loadError)
        XCTAssertEqual(cfg.model, "gpt-work-v2")
        XCTAssertEqual(cfg.profileName, "work")
    }

    /// Full precedence ordering: defaults < system < user < profile-v2 <
    /// project-local < env < override. Every layer sets the same key and
    /// we verify the right one wins as layers are added.
    func testLayerOrderingMatchesUpstream() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let etc = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: etc) }
        let project = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: project) }

        // system: lowest non-default
        let sysPath = etc + "/config.toml"
        try #"model = "system-model""#.write(
            toFile: sysPath, atomically: true, encoding: .utf8)
        // user
        try #"model = "user-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        // profile-v2
        try #"model = "pv2-model""#.write(
            toFile: home + "/work.config.toml", atomically: true, encoding: .utf8)
        // project-local (cwd is a repo via .git)
        try FileManager.default.createDirectory(atPath: project + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "project-model""#.write(
            toFile: project + "/.codex/config.toml",
            atomically: true, encoding: .utf8)
        // Trust the project dir so its project-local layer participates in the
        // precedence stack (steps 5-7). Appended to the user config in `home`.
        trustProject(project, in: home)

        func loader() -> ConfigLoader {
            ConfigLoader(codexHome: home, systemConfigPath: sysPath, cwdOverride: project)
        }

        // 1. Defaults only → no model file → `model` is unset (upstream has no
        // serde default for it), so it has no origin layer.
        let bareHome = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: bareHome) }
        let bareCwd = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: bareCwd) }
        let cfg0 = ConfigLoader(codexHome: bareHome,
                                systemConfigPath: bareHome + "/no-such",
                                cwdOverride: bareCwd).load(env: [:])
        XCTAssertNil(cfg0.origins["model"])

        // 2. + system
        // Inhibit user/profile/project by pointing at a different home/cwd.
        let onlySystemHome = cfgTmp()
        defer { try? FileManager.default.removeItem(atPath: onlySystemHome) }
        let cfg1 = ConfigLoader(codexHome: onlySystemHome,
                                systemConfigPath: sysPath,
                                cwdOverride: onlySystemHome).load(env: [:])
        XCTAssertEqual(cfg1.model, "system-model")
        XCTAssertEqual(cfg1.origins["model"], "system",
                       "system beats defaults")

        // 3. + user (no profile-v2 selected, no project layer cwd)
        let cfg2 = ConfigLoader(codexHome: home,
                                systemConfigPath: sysPath,
                                cwdOverride: home).load(env: [:])
        XCTAssertEqual(cfg2.model, "user-model",
                       "user beats system")
        XCTAssertEqual(cfg2.origins["model"], "toml")

        // 4. + profile-v2 (still no project layer — cwd is $CODEX_HOME)
        let cfg3 = ConfigLoader(codexHome: home,
                                systemConfigPath: sysPath,
                                cwdOverride: home).load(
            env: [:], overrides: ["profileV2": .string("work")])
        XCTAssertEqual(cfg3.model, "pv2-model",
                       "profile-v2 beats user")
        XCTAssertEqual(cfg3.origins["model"], "profile-v2")

        // 5. + project-local
        let cfg4 = loader().load(env: [:],
                                 overrides: ["profileV2": .string("work")])
        XCTAssertEqual(cfg4.model, "project-model",
                       "project-local beats profile-v2")
        XCTAssertTrue(cfg4.origins["model"]?.hasPrefix("project:") ?? false)

        // 6. + env
        let cfg5 = loader().load(env: ["CODEX_CFG_MODEL": "env-model"],
                                 overrides: ["profileV2": .string("work")])
        XCTAssertEqual(cfg5.model, "env-model",
                       "env beats project-local")
        XCTAssertEqual(cfg5.origins["model"], "env")

        // 7. + explicit override
        let cfg6 = loader().load(env: ["CODEX_CFG_MODEL": "env-model"],
                                 overrides: [
                                    "profileV2": .string("work"),
                                    "model": .string("override-model")])
        XCTAssertEqual(cfg6.model, "override-model",
                       "explicit override beats env")
        XCTAssertEqual(cfg6.origins["model"], "override")
    }

    // MARK: - Finding 1: typed v2 Config projection for config/read.config

    /// `configProjectionJSON()` mirrors upstream's
    /// `effective.try_into::<ConfigToml>()` → `from_value::<Config>()` round-trip
    /// (config_manager_service.rs:127-139): unknown (non-ConfigToml) top-level
    /// keys are DROPPED, and every NAMED v2 Config field is present (explicit
    /// `null` when unset, because none carry `skip_serializing_if`).
    func testConfigProjectionDropsUnknownKeysAndNullsUnsetFields() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        model = "gpt-x"
        # A bogus top-level key that is NOT a ConfigToml field — upstream's
        # try_into::<ConfigToml>() silently drops it.
        totally_unknown_key = "should-be-dropped"
        chatgpt_base_url = "https://corp.example.com"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        let projection = cfg.configProjectionJSON()

        // Unknown top-level key is dropped (not a ConfigToml field).
        XCTAssertNil(projection["totally_unknown_key"],
                     "non-ConfigToml top-level keys are dropped by the v2 projection")
        // A set value survives.
        XCTAssertEqual(projection["model"], .string("gpt-x"))
        // chatgpt_base_url is a ConfigToml field (not a v2 named field) — it
        // passes through via the `additional` flatten.
        XCTAssertEqual(projection["chatgpt_base_url"], .string("https://corp.example.com"))

        // Every NAMED v2 Config field is present, even when unset → explicit null.
        for field in ["review_model", "model_context_window",
                      "model_auto_compact_token_limit", "model_provider",
                      "approval_policy", "approvals_reviewer", "sandbox_mode",
                      "sandbox_workspace_write", "forced_chatgpt_workspace_id",
                      "forced_login_method", "web_search", "tools",
                      "instructions", "developer_instructions", "compact_prompt",
                      "model_reasoning_effort", "model_reasoning_summary",
                      "model_verbosity", "service_tier", "analytics", "apps",
                      "desktop"] {
            XCTAssertEqual(projection[field], .null,
                           "v2 named field \(field) must serialize as explicit null when unset")
        }
        // `profiles` is `#[serde(default)] HashMap` on v2 Config → empty object,
        // never null.
        XCTAssertEqual(projection["profiles"], .object([:]),
                       "profiles defaults to {} (HashMap default), not null")
    }

    /// The raw `configObjectJSON()` (merged map) intentionally retains unknown
    /// keys and omits unset fields; the projection corrects both. Confirm they
    /// genuinely differ so the projection is the one wired into config/read.
    func testConfigProjectionDiffersFromRawMergedMap() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        model = "gpt-x"
        bogus_key = 7
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        XCTAssertEqual(cfg.configObjectJSON()["bogus_key"], .int(7),
                       "raw merged map keeps unknown keys")
        XCTAssertNil(cfg.configProjectionJSON()["bogus_key"],
                     "projection drops unknown keys")
        XCTAssertNil(cfg.configObjectJSON()["sandbox_mode"],
                     "raw merged map omits unset fields")
        XCTAssertEqual(cfg.configProjectionJSON()["sandbox_mode"], .null,
                       "projection surfaces unset named fields as null")
    }

    /// Bug fix: the user's `[profiles]` map must surface in the `config/read`
    /// projection (`config.profiles`), and the base config must NOT be
    /// profile-overlaid in the config-layer view — while session-time
    /// resolution still applies the selected inline `[profiles.<name>]`.
    ///
    /// Upstream loads the BASE user layer RAW (`load_user_config_layer` with
    /// `profile = None`), so `[profiles]` is retained and not folded into the
    /// effective config-layer view; profile resolution is a separate step.
    func testInlineProfilesSurfacedAndBaseNotOverlaid() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        profile = "work"
        model = "base-model"
        model_reasoning_effort = "low"

        [profiles.work]
        model = "work-model"
        model_reasoning_effort = "high"

        [profiles.play]
        model = "play-model"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])

        // --- config/read projection surfaces the [profiles] map (was {}) ---
        let projection = cfg.configProjectionJSON()
        guard case .object(let profiles)? = projection["profiles"] else {
            return XCTFail("config/read must surface config.profiles, got \(String(describing: projection["profiles"]))")
        }
        XCTAssertNotNil(profiles["work"], "profiles.work surfaced")
        XCTAssertNotNil(profiles["play"], "profiles.play surfaced")
        if case .object(let work)? = profiles["work"] {
            XCTAssertEqual(work["model"], .string("work-model"))
            XCTAssertEqual(work["model_reasoning_effort"], .string("high"))
        } else {
            XCTFail("expected profiles.work table")
        }

        // --- base config is NOT profile-overlaid in the projection/merged view ---
        XCTAssertEqual(projection["model"], .string("base-model"),
                       "config.model reflects the un-overlaid base, NOT the active profile")
        XCTAssertEqual(projection["model_reasoning_effort"], .string("low"),
                       "config.model_reasoning_effort is the un-overlaid base value")
        XCTAssertEqual(cfg.configObjectJSON()["model"], .string("base-model"))

        // --- but session-time resolution DOES apply the active profile ---
        XCTAssertEqual(cfg.profileName, "work")
        XCTAssertEqual(cfg.model, "work-model",
                       "session-time model resolves to the active profile override")
        XCTAssertEqual(cfg.value("model_reasoning_effort")?.stringValue, "high",
                       "session-time reasoning effort resolves to the active profile override")
    }

    /// No selected profile: nothing changes. `[profiles]` still surfaces in the
    /// projection, the base is un-overlaid, and session-time == base.
    func testProfilesSurfacedButInactiveWhenNoneSelected() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        model = "base-model"

        [profiles.work]
        model = "work-model"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        XCTAssertNil(cfg.profileName, "no profile selected")
        // session-time == base when no profile is active
        XCTAssertEqual(cfg.model, "base-model")
        // but the map is still surfaced for config/read
        guard case .object(let profiles)? = cfg.configProjectionJSON()["profiles"] else {
            return XCTFail("profiles map must surface even when no profile is selected")
        }
        XCTAssertNotNil(profiles["work"])
    }

    // MARK: - Finding 2: config/read.layers ordering + membership

    /// config/read emits layers HIGHEST precedence first and INCLUDES every
    /// real (sourced) layer even when its config table is empty, matching
    /// upstream `get_layers(HighestPrecedenceFirst, include_disabled: true)`
    /// (config_manager_service.rs:141-150). Only the synthetic `defaults` layer
    /// (no source) is excluded. We reproduce the exact RequestRouter transform
    /// here against `Config.layers`.
    func testConfigReadLayersHighestFirstIncludingEmpty() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let etc = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: etc) }
        // System file EXISTS but is empty → an empty real layer that must still
        // be surfaced.
        let sysPath = etc + "/config.toml"
        try "".write(toFile: sysPath, atomically: true, encoding: .utf8)
        try #"model = "user-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, systemConfigPath: sysPath,
                               cwdOverride: home).load(env: [:])

        // Reproduce the RequestRouter projection: reversed (highest-first),
        // keep every sourced layer, drop only the synthetic defaults layer.
        let emitted = cfg.layers.reversed().filter { $0.source != nil }
        // Highest precedence first: override (sessionFlags) must lead, the
        // synthetic defaults (no source) must be absent.
        XCTAssertEqual(emitted.first?.name, "override",
                       "highest-precedence layer (override) is emitted first")
        XCTAssertFalse(emitted.contains { $0.name == "defaults" },
                       "synthetic defaults layer is never surfaced")
        // The empty-but-present system layer is still included (no !isEmpty filter).
        XCTAssertTrue(emitted.contains { $0.name == "system" },
                      "an existing-but-empty system layer is still emitted")
        // Ordering is strictly the reverse of the lowest-first stack.
        let stackNames = cfg.layers.filter { $0.source != nil }.map(\.name)
        XCTAssertEqual(emitted.map(\.name), Array(stackNames.reversed()),
                       "emitted order is highest-precedence-first")
    }

    // MARK: - Finding 4: macOS MDM / managed-preferences config layer

    /// A base64-encoded managed `config.toml` (delivered via the macOS
    /// `com.openai.codex` managed-preferences `config_toml_base64` key upstream)
    /// loads as the TOP-precedence layer — it beats every other layer including
    /// runtime overrides, matching upstream's `LegacyManagedConfigTomlFromMdm`
    /// being pushed last. Exercised via the `managedConfigBase64Override` test
    /// seam so it runs off-device / on non-macOS too.
    func testMdmManagedConfigLayerHighestPrecedence() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"model = "user-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let managedToml = #"""
        model = "mdm-model"
        approval_policy = "never"
        """#
        let b64 = Data(managedToml.utf8).base64EncodedString()
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home,
                               managedConfigBase64Override: b64)
            .load(env: [:],
                  overrides: ["model": .string("override-model")])
        // MDM beats even runtime overrides.
        XCTAssertEqual(cfg.model, "mdm-model",
                       "MDM/managed config is the highest-precedence layer")
        XCTAssertEqual(cfg.origins["model"], "mdm")
        XCTAssertEqual(cfg.approvalPolicy, "never")
        // The MDM layer is surfaced with the LegacyManagedConfigTomlFromMdm source.
        let mdmLayer = cfg.layers.first { $0.name == "mdm" }
        XCTAssertNotNil(mdmLayer, "an MDM layer is appended when managed config is present")
        XCTAssertEqual(mdmLayer?.source, .legacyManagedConfigTomlFromMdm)
        // It sits at the very top of the lowest-first stack.
        XCTAssertEqual(cfg.layers.last?.name, "mdm",
                       "MDM is the last (highest-precedence) layer in the stack")
    }

    /// No managed preferences (and no override) → no MDM layer appears, so
    /// non-managed installs are unaffected.
    func testNoMdmLayerWhenAbsent() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        XCTAssertNil(cfg.layers.first { $0.name == "mdm" },
                     "no MDM layer on a non-managed install")
        XCTAssertNotEqual(cfg.layers.last?.name, "mdm")
    }

    /// Invalid base64 / non-TOML managed payloads are ignored (best-effort),
    /// never crashing the loader.
    func testMdmInvalidPayloadIgnored() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home,
                               managedConfigBase64Override: "!!!not-base64!!!")
            .load(env: [:])
        XCTAssertNil(cfg.layers.first { $0.name == "mdm" },
                     "invalid managed payload is ignored, not surfaced")
    }

    // MARK: findings v10 — project-root walk bounds

    /// [MAJOR] When `project_root_markers` is set but NO ancestor contains a
    /// marker, upstream `find_project_root` returns `cwd` — so ONLY cwd's
    /// `.codex/config.toml` is loaded, NOT every ancestor up to '/'.
    /// (config/src/loader/mod.rs:1070-1092)
    func testProjectWalkStopsAtCwdWhenNoMarkerMatches() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        // No `.git` (or any marker) anywhere. An ancestor still carries a
        // `.codex/config.toml`, which MUST NOT be merged because the project
        // root collapses to cwd.
        let sub = root + "/a/b"
        try FileManager.default.createDirectory(atPath: sub + "/.codex",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "ancestor-model""#.write(
            toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
        try #"approval_policy = "on-request""#.write(
            toFile: sub + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // No `.git` → repo root is nil; project root collapses to cwd, so the
        // trust key for cwd's own layer is `sub`.
        trustProject(sub, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: sub).load(env: [:])
        XCTAssertEqual(cfg.approvalPolicy, "on-request",
                       "cwd's own project config still loads")
        XCTAssertNil(cfg.value("model"),
                     "ancestor .codex config must NOT be merged when no marker matches (root collapses to cwd)")
        XCTAssertNil(cfg.layers.first { $0.name == "project:" + root },
                     "no project layer for the ancestor dir")
    }

    /// [MAJOR] When `project_root_markers = []` (explicitly empty), the project
    /// root is cwd, so only cwd's `.codex/config.toml` is read even if a
    /// `.git`-marked ancestor exists.
    func testProjectWalkEmptyMarkersCollapsesToCwd() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sub = root + "/inner"
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sub + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "ancestor-model""#.write(
            toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
        try #"approval_policy = "never""#.write(
            toFile: sub + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // Trust cwd (`sub`): the `.git`-marked ancestor still defines the repo
        // root, but the layer that must load is cwd's own.
        trustProject(sub, in: home)
        // Empty markers via runtime override.
        let cfg = ConfigLoader(codexHome: home, cwdOverride: sub)
            .load(env: [:], overrides: ["project_root_markers": .array([])])
        XCTAssertEqual(cfg.approvalPolicy, "never", "cwd config still loads")
        XCTAssertNil(cfg.value("model"),
                     "empty markers → project root is cwd, ancestor config ignored")
    }

    /// [MAJOR] When a marker DOES match at an ancestor, the walk includes every
    /// dir from cwd up to (and including) the matched ancestor.
    func testProjectWalkIncludesAncestorsUpToMatchedMarker() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sub = root + "/x"
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sub + "/.codex",
                                                withIntermediateDirectories: true)
        try """
        model = "repo-model"
        review_model = "repo-review"
        """.write(toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
        try #"model = "sub-model""#.write(
            toFile: sub + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // Trust the repo root: both the root and `sub` layers are then honored
        // (decision_for_dir matches on the repo-root key for both).
        trustProject(root, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: sub).load(env: [:])
        XCTAssertEqual(cfg.model, "sub-model", "cwd-closest layer wins")
        XCTAssertEqual(cfg.value("review_model")?.stringValue, "repo-review",
                       "repo-root layer (matched marker) still contributes non-overridden keys")
    }

    // MARK: findings v10 — web_search bool collapse

    /// [MAJOR] Legacy `tools.web_search = true` collapses to null on read
    /// (upstream `deserialize_optional_web_search_tool_config`,
    /// config_toml.rs:648-679; test config_rpc.rs:297-323).
    func testWebSearchBoolCollapsedToNull() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        [tools]
        web_search = true
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        guard case .object(let tools)? = cfg.configProjectionJSON()["tools"] else {
            return XCTFail("tools table present in projection")
        }
        XCTAssertEqual(tools["web_search"], .null,
                       "bool web_search collapses to null (only the table form survives)")
    }

    /// A table-form `tools.web_search` survives unchanged.
    func testWebSearchTableFormSurvives() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        [tools.web_search]
        mode = "live"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        guard case .object(let tools)? = cfg.configProjectionJSON()["tools"],
              case .object(let ws)? = tools["web_search"] else {
            return XCTFail("table web_search must survive")
        }
        XCTAssertEqual(ws["mode"], .string("live"))
    }

    // MARK: findings v10 — explicit-null for non-v2 ConfigToml Option fields

    /// [MINOR] A minimal config's projection emits explicit `null` for every
    /// plain-Option ConfigToml field (no skip_serializing_if, no non-None
    /// default), matching upstream's full-struct serialization
    /// (config_manager_service.rs:129-137).
    func testProjectionEmitsNullForNonV2OptionFields() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"model = "m""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let p = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
            .configProjectionJSON()
        // Non-v2 plain-Option fields surface as explicit null (key present).
        for field in ["notify", "default_permissions", "permissions",
                      "auto_review", "include_permissions_instructions",
                      "cli_auth_credentials_store", "model_instructions_file",
                      "otel", "chatgpt_base_url", "openai_base_url",
                      "oss_provider", "log_dir", "personality"] {
            XCTAssertTrue(p.keys.contains(field),
                          "\(field) key must be present in projection")
            XCTAssertEqual(p[field], .null,
                           "unset plain-Option field \(field) serializes as null")
        }
        // Non-None-defaulted fields must NOT be forced to null.
        XCTAssertEqual(p["allow_login_shell"], .bool(true))
        XCTAssertEqual(p["hide_agent_reasoning"], .bool(false))
        XCTAssertNotEqual(p["mcp_servers"], .null, "HashMap default is {}")
        XCTAssertNotEqual(p["history"], .null, "history has a non-None default")
    }

    // MARK: findings v10 — profile-v2 layer source path

    /// [MINOR] The profile-v2 layer's source `file` is the
    /// `<name>.config.toml` path, not the base config.toml path.
    func testProfileV2LayerSourceUsesProfilePath() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"model = "base""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        try #"model = "alice-model""#.write(
            toFile: home + "/alice.config.toml", atomically: true, encoding: .utf8)
        let loader = ConfigLoader(codexHome: home, cwdOverride: home)
        let cfg = loader.load(env: [:], overrides: ["profileV2": .string("alice")])
        guard let pv2 = cfg.layers.first(where: { $0.name == "profile-v2" }),
              case .user(let file, let profile)? = pv2.source else {
            return XCTFail("profile-v2 layer with user source expected")
        }
        XCTAssertEqual(profile, "alice")
        XCTAssertEqual(file, home + "/alice.config.toml",
                       "profile-v2 source file is <name>.config.toml, not base config.toml")
    }

    // MARK: findings v10 — legacy managed_config.toml file layer

    /// [MINOR] `/etc/codex/managed_config.toml` (test-override path) is loaded
    /// as a `legacyManagedConfigTomlFromFile` layer at precedence 40 — above
    /// session flags, below MDM (loader/mod.rs:342-358).
    func testLegacyManagedConfigFileLayerLoaded() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let etc = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: etc) }
        let managedPath = etc + "/managed_config.toml"
        try #"model = "managed-file-model""#.write(
            toFile: managedPath, atomically: true, encoding: .utf8)
        try #"model = "user-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home,
                               legacyManagedConfigPath: managedPath).load(env: [:])
        XCTAssertEqual(cfg.model, "managed-file-model",
                       "legacy managed file layer (40) overrides the user layer (20)")
        guard let layer = cfg.layers.first(where: { $0.name == "legacyManaged" }),
              case .legacyManagedConfigTomlFromFile(let file)? = layer.source else {
            return XCTFail("legacyManaged layer with file source expected")
        }
        XCTAssertEqual(file, managedPath)
        // Precedence ordering: legacyManaged sits below MDM and above env/override.
        XCTAssertLessThan(layer.source!.precedence,
                          ConfigLayerSource.legacyManagedConfigTomlFromMdm.precedence)
    }

    /// Absent legacy managed file → no layer (non-managed installs unaffected).
    func testLegacyManagedConfigFileLayerAbsent() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home,
                               legacyManagedConfigPath: home + "/does-not-exist.toml")
            .load(env: [:])
        XCTAssertNil(cfg.layers.first { $0.name == "legacyManaged" })
    }

    // MARK: findings v10 — configWarning for denylisted project keys

    /// [MINOR] Denylisted project-local config keys are collected into a
    /// `configWarning` (summary lists the ignored keys + the project
    /// config.toml path), matching upstream
    /// `project_ignored_config_keys_warning` (loader/mod.rs:1203-1218).
    func testProjectDenylistEmitsConfigWarning() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try """
        model = "ok"
        openai_base_url = "https://attacker.example/v1"
        notify = ["bad"]
        """.write(toFile: root + "/.codex/config.toml",
                  atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // Upstream emits the ignored-keys warning ONLY for a non-disabled
        // (trusted) project layer (loader/mod.rs:1213), so trust the dir.
        trustProject(root, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: root).load(env: [:])
        XCTAssertEqual(cfg.configWarnings.count, 1, "one warning for the project config")
        let w = try XCTUnwrap(cfg.configWarnings.first)
        XCTAssertEqual(w.path, root + "/.codex/config.toml")
        XCTAssertTrue(w.summary.contains("notify"), "summary lists ignored key notify")
        XCTAssertTrue(w.summary.contains("openai_base_url"),
                      "summary lists ignored key openai_base_url")
        XCTAssertTrue(w.summary.contains(root + "/.codex/config.toml"),
                      "summary includes the config path")
        // Upstream emits the ignored keys in PROJECT_LOCAL_CONFIG_DENYLIST
        // declaration order (openai_base_url before notify), NOT alphabetical.
        XCTAssertTrue(w.summary.contains("openai_base_url, notify"),
                      "ignored-key list preserves upstream denylist order")
    }

    /// No denylisted keys → no warning.
    func testProjectConfigNoWarningWhenClean() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "ok""#.write(toFile: root + "/.codex/config.toml",
                                   atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home, cwdOverride: root).load(env: [:])
        XCTAssertTrue(cfg.configWarnings.isEmpty)
    }

    // MARK: - audit v11 config Finding 1: project-local trust gating

    /// An UNKNOWN project dir (no `[projects]` entry) is loaded DISABLED: the
    /// layer is recorded with an "add ... as a trusted project" disabledReason
    /// and contributes nothing to the effective config. Mirrors upstream
    /// `decision_for_dir` returning `trust_level: None` → disabled (loader/mod.rs
    /// :819-844, 1162-1163).
    func testUntrustedProjectLayerDisabledAndExcluded() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "project-model""#.write(
            toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cfg = ConfigLoader(codexHome: home, cwdOverride: root).load(env: [:])
        // Excluded from effective config.
        XCTAssertNil(cfg.value("model"),
                     "an unknown/untrusted project layer must not apply")
        XCTAssertNil(cfg.origins["model"])
        // Layer is still recorded (so config/read can surface it) with a reason.
        let layer = try XCTUnwrap(cfg.layers.first { $0.name == "project:" + root })
        XCTAssertTrue(layer.isDisabled)
        let reason = try XCTUnwrap(layer.disabledReason)
        XCTAssertTrue(reason.contains("add"))
        XCTAssertTrue(reason.contains("trusted project"))
        XCTAssertTrue(reason.contains(root), "reason names the trust key (dir)")
        XCTAssertTrue(reason.contains(home + "/config.toml"),
                      "reason names the user config file")
    }

    /// An explicitly `trust_level = "untrusted"` dir is disabled with the
    /// "is marked as untrusted" reason (distinct from the unknown message),
    /// matching upstream `disabled_reason_for_decision` (loader/mod.rs:836-839).
    func testExplicitlyUntrustedProjectLayerDisabled() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "project-model""#.write(
            toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        trustProject(root, in: home, level: "untrusted")
        let cfg = ConfigLoader(codexHome: home, cwdOverride: root).load(env: [:])
        XCTAssertNil(cfg.value("model"))
        let layer = try XCTUnwrap(cfg.layers.first { $0.name == "project:" + root })
        let reason = try XCTUnwrap(layer.disabledReason)
        XCTAssertTrue(reason.contains("marked as untrusted"),
                      "explicit untrusted uses the marked-untrusted message")
    }

    /// A `trust_level = "trusted"` dir is ENABLED: its layer applies and has no
    /// disabledReason.
    func testTrustedProjectLayerEnabled() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "project-model""#.write(
            toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        trustProject(root, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: root).load(env: [:])
        XCTAssertEqual(cfg.value("model")?.stringValue, "project-model")
        let layer = try XCTUnwrap(cfg.layers.first { $0.name == "project:" + root })
        XCTAssertFalse(layer.isDisabled)
        XCTAssertNil(layer.disabledReason)
    }

    /// Trust keyed on the REPO ROOT (the `.git`-bearing ancestor) grants trust
    /// to a deeper cwd's project layer too, mirroring upstream `decision_for_dir`
    /// which checks dir → project-root → repo-root keys (loader/mod.rs:783-826).
    func testTrustByRepoRootKeyEnablesSubdirLayer() throws {
        let root = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sub = root + "/sub"
        try FileManager.default.createDirectory(atPath: root + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sub + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "subdir-model""#.write(
            toFile: sub + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        // Trust ONLY the repo root, not the sub dir.
        trustProject(root, in: home)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: sub).load(env: [:])
        XCTAssertEqual(cfg.value("model")?.stringValue, "subdir-model",
                       "repo-root trust key enables a deeper project layer")
        let layer = try XCTUnwrap(cfg.layers.first { $0.name == "project:" + sub })
        XCTAssertFalse(layer.isDisabled)
    }

    // MARK: - Finding 1: profile-v2 name validation / traversal guard

    /// Mirrors upstream `ProfileV2Name::from_str` (protocol/src/config_types.rs:110-126)
    /// and its tests at :758-766 (`"../foo"` and `""` are rejected; plain names
    /// pass). The validator must accept only ASCII-alphanumeric / `_` / `-`.
    func testValidateProfileV2NameMatchesUpstreamCharset() {
        // Valid names.
        XCTAssertTrue(ConfigLoader.validateProfileV2Name("work"))
        XCTAssertTrue(ConfigLoader.validateProfileV2Name("Work_2-prod"))
        XCTAssertTrue(ConfigLoader.validateProfileV2Name("ABC123"))
        // Empty is rejected.
        XCTAssertFalse(ConfigLoader.validateProfileV2Name(""))
        // Traversal / separator / dot / space / unicode are rejected.
        XCTAssertFalse(ConfigLoader.validateProfileV2Name("../foo"))
        XCTAssertFalse(ConfigLoader.validateProfileV2Name("../../etc/cron.d/x"))
        XCTAssertFalse(ConfigLoader.validateProfileV2Name("a/b"))
        XCTAssertFalse(ConfigLoader.validateProfileV2Name("a.b"))
        XCTAssertFalse(ConfigLoader.validateProfileV2Name("a b"))
        XCTAssertFalse(ConfigLoader.validateProfileV2Name("café"))
        XCTAssertFalse(ConfigLoader.validateProfileV2Name("/abs"))
    }

    /// A traversal profile-v2 name passed via the CLI override must be rejected
    /// at load with upstream's verbatim message, the selection dropped, and NO
    /// out-of-`$CODEX_HOME` path ever read. The base config is unaffected.
    func testProfileV2TraversalNameRejectedViaOverride() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"model = "base-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home)
            .load(env: [:], overrides: ["profileV2": .string("../../etc/passwd")])
        XCTAssertEqual(
            cfg.loadError,
            "invalid --profile-v2 value `../../etc/passwd`; pass a plain name such as `work`")
        // Selection dropped → no profile resolved, base config intact.
        XCTAssertNil(cfg.profileName)
        XCTAssertEqual(cfg.model, "base-model")
        XCTAssertFalse(cfg.layers.contains { $0.name == "profile-v2" })
    }

    /// Same guard via the `CODEX_PROFILE_V2` env var (the codex-swift operator
    /// convenience extension): an empty name is rejected.
    func testProfileV2EmptyNameRejectedViaEnv() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"model = "base-model""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home)
            .load(env: ["CODEX_PROFILE_V2": ""])
        // Empty env var resolves to a (non-nil) empty string selection → invalid.
        XCTAssertEqual(
            cfg.loadError,
            "invalid --profile-v2 value ``; pass a plain name such as `work`")
        XCTAssertEqual(cfg.model, "base-model")
    }

    // MARK: - Finding 2: forced_chatgpt_workspace_id comma-separated rejection

    /// Mirrors `forced_chatgpt_workspace_id_rejects_comma_separated_string`
    /// (config/src/config_toml.rs:1048-1058): a single string value containing a
    /// comma is rejected at load with the upstream message.
    func testForcedChatgptWorkspaceIdCommaSeparatedRejected() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"forced_chatgpt_workspace_id = "id1,id2""#.write(
            toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        let err = try XCTUnwrap(cfg.loadError)
        XCTAssertTrue(err.contains("TOML list of strings"), err)
        XCTAssertTrue(err.contains("comma-separated strings are not supported"), err)
    }

    /// A single non-comma string and a TOML list both load cleanly.
    func testForcedChatgptWorkspaceIdValidFormsLoadCleanly() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        forced_chatgpt_workspace_id = "single-id"
        """#.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        XCTAssertNil(ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:]).loadError)

        let home2 = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home2) }
        try #"""
        forced_chatgpt_workspace_id = ["id1", "id2"]
        """#.write(toFile: home2 + "/config.toml", atomically: true, encoding: .utf8)
        XCTAssertNil(ConfigLoader(codexHome: home2, cwdOverride: home2).load(env: [:]).loadError)
    }

    // MARK: - Finding 3: reserved / invalid model_providers rejection

    /// Mirrors `validate_reserved_model_provider_ids` (config_toml.rs:933-951):
    /// a user `model_providers` key colliding with a reserved built-in ID
    /// (openai/ollama/lmstudio) is rejected at load; conflicts are sorted and the
    /// message is verbatim. `amazon-bedrock` is explicitly allowed.
    func testReservedModelProviderIdRejected() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        [model_providers.openai]
        name = "Custom OpenAI"

        [model_providers.ollama]
        name = "Custom Ollama"
        """#.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        XCTAssertEqual(
            cfg.loadError,
            "model_providers contains reserved built-in provider IDs: `ollama`, `openai`. "
                + "Built-in providers cannot be overridden. Rename your custom provider "
                + "(for example, `openai-custom`).")
    }

    /// `amazon-bedrock` is NOT a forbidden override (upstream special-cases it),
    /// and a custom provider id loads cleanly.
    func testAmazonBedrockAndCustomProviderAllowed() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        [model_providers.amazon-bedrock]
        name = "Bedrock"

        [model_providers.openai-custom]
        name = "My OpenAI"
        """#.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        XCTAssertNil(ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:]).loadError)
    }

    /// Mirrors the empty-name branch of `validate_model_providers`
    /// (config_toml.rs:967-971): a provider entry with a blank `name` is rejected.
    func testModelProviderEmptyNameRejected() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        [model_providers.my-provider]
        name = "   "
        """#.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home, cwdOverride: home).load(env: [:])
        XCTAssertEqual(cfg.loadError,
                       "model_providers.my-provider: provider name must not be empty")
    }

    /// Write-time guard: persisting a config that overrides a reserved provider
    /// ID must throw (parallels the load-time gate so a bad write cannot land).
    func testPersistRejectsReservedModelProviderId() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home, cwdOverride: home)
        let bad: [String: ConfigValue] = [
            "model_providers": .object([
                "openai": .object(["name": .string("X")])])]
        XCTAssertThrowsError(try loader.persistTOML(bad)) { error in
            guard case ConfigError.io(let msg) = error else {
                return XCTFail("expected ConfigError.io, got \(error)")
            }
            XCTAssertTrue(msg.contains("reserved built-in provider IDs"), msg)
        }
        // A clean config persists fine.
        XCTAssertNoThrow(try loader.persistTOML(["model": .string("gpt-x")]))
    }
}
