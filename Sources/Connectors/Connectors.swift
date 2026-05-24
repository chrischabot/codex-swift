import Foundation

/// A configured connector (Codex `connectors`). Surfaced to the model in the
/// prompt's connector section and listable via the protocol.
public struct ConnectorRecord: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var description: String
    public var logoUrl: String?
    public var logoUrlDark: String?
    public var distributionChannel: String?
    public var installUrl: String?
    public var labels: [String: String]?
    public var isAccessible: Bool
    public var pluginDisplayNames: [String]

    public init(id: String, name: String, description: String,
                logoUrl: String? = nil, logoUrlDark: String? = nil,
                distributionChannel: String? = nil, installUrl: String? = nil,
                labels: [String: String]? = nil, isAccessible: Bool = true,
                pluginDisplayNames: [String] = []) {
        self.id = id; self.name = name; self.description = description
        self.logoUrl = logoUrl; self.logoUrlDark = logoUrlDark
        self.distributionChannel = distributionChannel; self.installUrl = installUrl
        self.labels = labels; self.isAccessible = isAccessible
        self.pluginDisplayNames = pluginDisplayNames
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, logoUrl, logoUrlDark, distributionChannel
        case installUrl, labels, isAccessible, pluginDisplayNames
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        logoUrl = try c.decodeIfPresent(String.self, forKey: .logoUrl)
        logoUrlDark = try c.decodeIfPresent(String.self, forKey: .logoUrlDark)
        distributionChannel = try c.decodeIfPresent(String.self, forKey: .distributionChannel)
        installUrl = try c.decodeIfPresent(String.self, forKey: .installUrl)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        isAccessible = try c.decodeIfPresent(Bool.self, forKey: .isAccessible) ?? true
        pluginDisplayNames = try c.decodeIfPresent([String].self, forKey: .pluginDisplayNames) ?? []
    }
}

/// Loads connectors from `$CODEX_HOME/connectors.json`:
/// `{ "connectors": [ { "id", "name", "description" } ] }`. Pure, `Sendable`,
/// dependency-free. Absent/malformed config → no connectors (Codex treats
/// connectors as optional).
public struct ConnectorsDiscovery: Sendable {
    public init() {}

    public func discover(codexHome: String) -> [ConnectorRecord] {
        let path = codexHome + "/connectors.json"
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        struct File: Decodable { var connectors: [ConnectorRecord] }
        let decoded = (try? JSONDecoder().decode(File.self, from: data))?.connectors ?? []
        return decoded.sorted { $0.id < $1.id }
    }
}
