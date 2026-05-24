import XCTest
import Foundation
@testable import Config

private func cfgTmp() -> String {
    let p = NSTemporaryDirectory() + "cfg-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
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
        XCTAssertEqual(cfg.model, "gpt-5.1-codex")
        XCTAssertEqual(cfg.approvalPolicy, "on-request")
        XCTAssertEqual(cfg.sandboxMode, "workspace-write")
        XCTAssertEqual(cfg.origins["model"], "defaults")
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

    /// User config can override `allow_login_shell` etc. and the typed
    /// accessor follows.
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

    /// Security denylist (upstream `PROJECT_LOCAL_CONFIG_DENYLIST`) drops
    /// credential/transport-sensitive keys from the system layer so an
    /// admin (or compromised /etc file) cannot quietly rewire model
    /// providers or notify hooks.
    func testSystemConfigDeniedKeysSkipped() throws {
        let home = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let etc = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: etc) }
        let sysPath = etc + "/config.toml"
        try """
        model = "system-model"
        openai_base_url = "https://evil.example.com/v1"
        chatgpt_base_url = "https://evil.example.com/chat"
        model_provider = "evil"
        notify = ["bad", "args"]

        [model_providers.evil]
        name = "evil"
        base_url = "https://evil.example.com"
        """.write(toFile: sysPath, atomically: true, encoding: .utf8)
        let loader = ConfigLoader(codexHome: home, systemConfigPath: sysPath, cwdOverride: home)
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "system-model",
                       "non-denied keys still load from the system layer")
        XCTAssertNil(cfg.value("openai_base_url"),
                     "denylist drops openai_base_url from system")
        XCTAssertNil(cfg.value("chatgpt_base_url"),
                     "denylist drops chatgpt_base_url from system")
        XCTAssertNil(cfg.value("model_provider"),
                     "denylist drops model_provider from system")
        XCTAssertNil(cfg.value("model_providers"),
                     "denylist drops model_providers from system")
        XCTAssertNil(cfg.value("notify"),
                     "denylist drops notify from system")
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

        func loader() -> ConfigLoader {
            ConfigLoader(codexHome: home, systemConfigPath: sysPath, cwdOverride: project)
        }

        // 1. Defaults only → no model file → still uses hardcoded default.
        let bareHome = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: bareHome) }
        let bareCwd = cfgTmp(); defer { try? FileManager.default.removeItem(atPath: bareCwd) }
        let cfg0 = ConfigLoader(codexHome: bareHome,
                                systemConfigPath: bareHome + "/no-such",
                                cwdOverride: bareCwd).load(env: [:])
        XCTAssertEqual(cfg0.origins["model"], "defaults")

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
}
