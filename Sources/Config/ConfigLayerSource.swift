import Foundation
import InfraPrimitives

/// Mirror of upstream `ConfigLayerSource`
/// (app-server-protocol/src/protocol/v2/config.rs:26) — an internally-tagged
/// (`{"type": ...}`, camelCase) enum identifying where a config layer came
/// from. Surfaced in `config/read` `origins` (one entry per dotted leaf path)
/// and in each `ConfigLayer.name`.
public enum ConfigLayerSource: Sendable, Equatable {
    case mdm(domain: String, key: String)
    case system(file: String)
    case user(file: String, profile: String?)
    case project(dotCodexFolder: String)
    case sessionFlags
    case legacyManagedConfigTomlFromFile(file: String)
    case legacyManagedConfigTomlFromMdm

    /// Upstream `precedence()` (config.rs:87-103): higher wins. Values match
    /// upstream exactly; the user no-profile/profile split is honored.
    public var precedence: Int {
        switch self {
        case .mdm: return 0
        case .system: return 10
        case .user(_, let profile): return profile == nil ? 20 : 21
        case .project: return 25
        case .sessionFlags: return 30
        case .legacyManagedConfigTomlFromFile: return 40
        case .legacyManagedConfigTomlFromMdm: return 50
        }
    }

    /// Internally-tagged JSON, camelCase keys — matches upstream serde.
    public func toJSON() -> ConfigValue {
        switch self {
        case .mdm(let domain, let key):
            return .object(["type": .string("mdm"),
                            "domain": .string(domain), "key": .string(key)])
        case .system(let file):
            return .object(["type": .string("system"), "file": .string(file)])
        case .user(let file, let profile):
            return .object(["type": .string("user"), "file": .string(file),
                            "profile": profile.map(ConfigValue.string) ?? .null])
        case .project(let dot):
            return .object(["type": .string("project"),
                            "dotCodexFolder": .string(dot)])
        case .sessionFlags:
            return .object(["type": .string("sessionFlags")])
        case .legacyManagedConfigTomlFromFile(let file):
            return .object(["type": .string("legacyManagedConfigTomlFromFile"),
                            "file": .string(file)])
        case .legacyManagedConfigTomlFromMdm:
            return .object(["type": .string("legacyManagedConfigTomlFromMdm")])
        }
    }
}

/// Per-leaf-path origin metadata: `{ name: ConfigLayerSource, version }`
/// (upstream `ConfigLayerMetadata`).
public struct ConfigLayerMetadata: Sendable, Equatable {
    public var name: ConfigLayerSource
    public var version: String
    public init(name: ConfigLayerSource, version: String) {
        self.name = name; self.version = version
    }
    public func toJSON() -> ConfigValue {
        .object(["name": name.toJSON(), "version": .string(version)])
    }
}

public enum ConfigCanonicalVersion {
    /// Upstream `version_for_toml` (config/src/fingerprint.rs): the literal
    /// token `"sha256:"` followed by the lowercase-hex sha256 of the
    /// canonical-JSON serialization of the layer value.
    public static func version(of values: [String: ConfigValue]) -> String {
        "sha256:" + Hashing.sha256Hex(canonicalString(.object(values)))
    }

    /// Deterministic canonical JSON: object keys sorted lexicographically,
    /// no insignificant whitespace. Matches the shape upstream hashes.
    static func canonicalString(_ v: ConfigValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .string(let s): return encodeJSONString(s)
        case .array(let a):
            return "[" + a.map(canonicalString).joined(separator: ",") + "]"
        case .object(let o):
            let parts = o.keys.sorted().map { k in
                encodeJSONString(k) + ":" + canonicalString(o[k]!)
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    private static func encodeJSONString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }
}
