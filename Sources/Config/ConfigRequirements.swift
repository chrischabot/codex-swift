import Foundation

public struct ConfigRequirementsSource: Sendable, Equatable {
    public var name: String
    public var path: String?
    public var values: [String: ConfigValue]

    public init(name: String, path: String?, values: [String: ConfigValue]) {
        self.name = name
        self.path = path
        self.values = values
    }
}

public struct ConfigRequirementsLoader: Sendable {
    public let systemRequirementsPath: String
    public let legacyManagedConfigPath: String
    public let managedPreferenceDomain: String
    public let managedPreferenceKey: String

    public init(systemRequirementsPath: String? = nil,
                legacyManagedConfigPath: String? = nil,
                managedPreferenceDomain: String = "com.openai.codex",
                managedPreferenceKey: String = "requirements_toml_base64") {
        #if os(Windows)
        let defaultRequirements = ProcessInfo.processInfo.environment["ProgramData"]
            .map { $0 + "\\OpenAI\\Codex\\requirements.toml" }
            ?? (NSHomeDirectory() + "\\.codex\\requirements.toml")
        let defaultManagedConfig = NSHomeDirectory() + "\\.codex\\managed_config.toml"
        #else
        let defaultRequirements = "/etc/codex/requirements.toml"
        let defaultManagedConfig = "/etc/codex/managed_config.toml"
        #endif
        self.systemRequirementsPath = systemRequirementsPath ?? defaultRequirements
        self.legacyManagedConfigPath = legacyManagedConfigPath ?? defaultManagedConfig
        self.managedPreferenceDomain = managedPreferenceDomain
        self.managedPreferenceKey = managedPreferenceKey
    }

    public func load() throws -> [String: ConfigValue]? {
        let sources = try loadSources()
        guard !sources.isEmpty else { return nil }
        var merged: [String: ConfigValue] = [:]
        for source in sources {
            fillMissing(into: &merged, from: source.values)
        }
        guard !merged.isEmpty else { return nil }
        return canonicalWireShape(merged)
    }

    public func loadSources() throws -> [ConfigRequirementsSource] {
        var sources: [ConfigRequirementsSource] = []
        if let mdm = try loadManagedPreferences() {
            sources.append(ConfigRequirementsSource(
                name: "mdm", path: "\(managedPreferenceDomain):\(managedPreferenceKey)",
                values: mdm))
        }
        if let system = try loadTOMLFile(systemRequirementsPath) {
            sources.append(ConfigRequirementsSource(
                name: "system", path: systemRequirementsPath, values: system))
        }
        if let legacy = try loadLegacyManagedConfig() {
            sources.append(ConfigRequirementsSource(
                name: "legacyManagedConfig", path: legacyManagedConfigPath,
                values: legacy))
        }
        return sources
    }

    private func loadManagedPreferences() throws -> [String: ConfigValue]? {
        guard let encoded = UserDefaults(suiteName: managedPreferenceDomain)?
            .string(forKey: managedPreferenceKey),
              !encoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.io("invalid base64 in \(managedPreferenceDomain):\(managedPreferenceKey)")
        }
        return try TOML.parse(text)
    }

    private func loadTOMLFile(_ path: String) throws -> [String: ConfigValue]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try TOML.parse(text)
    }

    private func loadLegacyManagedConfig() throws -> [String: ConfigValue]? {
        guard let root = try loadTOMLFile(legacyManagedConfigPath) else { return nil }
        var out: [String: ConfigValue] = [:]
        if let approval = root["approval_policy"] ?? root["approvalPolicy"] {
            out["allowed_approval_policies"] = .array([approval])
        }
        if let sandbox = root["sandbox_mode"] ?? root["sandboxMode"] {
            out["allowed_sandbox_modes"] = .array([sandbox])
        }
        return out.isEmpty ? nil : out
    }

    private func fillMissing(into target: inout [String: ConfigValue],
                             from source: [String: ConfigValue]) {
        for (key, value) in source {
            if case .object(var current)? = target[key],
               case .object(let incoming) = value {
                fillMissing(into: &current, from: incoming)
                target[key] = .object(current)
            } else if target[key] == nil {
                target[key] = value
            }
        }
    }

    private func canonicalWireShape(_ root: [String: ConfigValue]) -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for (key, value) in root {
            switch key {
            case "features":
                out["featureRequirements"] = canonicalValue(value)
            case "experimental_network":
                out["network"] = canonicalValue(value)
            default:
                out[camelCase(key)] = canonicalValue(value)
            }
        }
        return out
    }

    private func canonicalValue(_ value: ConfigValue) -> ConfigValue {
        switch value {
        case .object(let object):
            var out: [String: ConfigValue] = [:]
            for (key, child) in object {
                out[camelCase(key)] = canonicalValue(child)
            }
            return .object(out)
        case .array(let values):
            return .array(values.map(canonicalValue))
        default:
            return value
        }
    }

    private func camelCase(_ key: String) -> String {
        let parts = key.split(separator: "_", omittingEmptySubsequences: false)
        guard let first = parts.first else { return key }
        return String(first) + parts.dropFirst().map { part in
            guard let head = part.first else { return "" }
            return String(head).uppercased() + part.dropFirst()
        }.joined()
    }
}
