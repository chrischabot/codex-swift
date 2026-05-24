import Foundation

/// Wire protocol for a model provider (Codex `WireApi`).
///
/// Upstream removed Chat Completions support (`wire_api = "chat"`) and now
/// hard-errors when it appears in a provider config. We mirror that: the only
/// valid variant is `.responses`. See
/// `~/Projects/codex/codex-rs/model-provider-info/src/lib.rs`
/// (`CHAT_WIRE_API_REMOVED_ERROR`).
public enum WireApi: String, Sendable, Codable, Equatable {
    case responses
}

/// Errors thrown while constructing a `ModelProviderRegistry` from raw
/// config values.
public enum ModelProviderConfigError: Error, Equatable, CustomStringConvertible {
    /// `wire_api = "chat"` is no longer supported (Responses-only).
    case chatWireApiRemoved(providerId: String)
    /// `wire_api` was set to a value other than `responses` or `chat`.
    case unknownWireApi(providerId: String, value: String)

    public var description: String {
        switch self {
        case .chatWireApiRemoved(let id):
            return "[\(id)] `wire_api = \"chat\"` is no longer supported.\n"
                 + "How to fix: set `wire_api = \"responses\"` in your "
                 + "provider config.\n"
                 + "More info: "
                 + "https://github.com/openai/codex/discussions/7782"
        case .unknownWireApi(let id, let value):
            return "[\(id)] unknown `wire_api = \"\(value)\"`; "
                 + "expected `responses`."
        }
    }
}

/// Faithful port of codex `ModelProviderInfo`.
public struct ModelProvider: Sendable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var envKey: String?
    public var experimentalBearerToken: String?
    public var wireApi: WireApi
    public var queryParams: [String: String]
    public var httpHeaders: [String: String]
    public var envHttpHeaders: [String: String]
    public var requestMaxRetries: Int
    public var requiresOpenAIAuth: Bool
    public var supportsWebsockets: Bool

    public init(id: String,
                name: String,
                baseURL: String,
                envKey: String? = nil,
                experimentalBearerToken: String? = nil,
                wireApi: WireApi = .responses,
                queryParams: [String: String] = [:],
                httpHeaders: [String: String] = [:],
                envHttpHeaders: [String: String] = [:],
                requestMaxRetries: Int = 4,
                requiresOpenAIAuth: Bool = false,
                supportsWebsockets: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.envKey = envKey
        self.experimentalBearerToken = experimentalBearerToken
        self.wireApi = wireApi
        self.queryParams = queryParams
        self.httpHeaders = httpHeaders
        self.envHttpHeaders = envHttpHeaders
        self.requestMaxRetries = requestMaxRetries
        self.requiresOpenAIAuth = requiresOpenAIAuth
        self.supportsWebsockets = supportsWebsockets
    }

    /// Built-in OpenAI provider (Codex default).
    public static let openAI = ModelProvider(
        id: "openai",
        name: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        envKey: "OPENAI_API_KEY",
        wireApi: .responses,
        requiresOpenAIAuth: true,
        supportsWebsockets: true)

    /// `Authorization` header value: experimental bearer token wins, else the
    /// env-var-resolved key, else nil.
    public func effectiveAuthHeader(env: [String: String]) -> String? {
        if let t = experimentalBearerToken, !t.isEmpty {
            return "Bearer \(t)"
        }
        if let k = envKey, let v = env[k], !v.isEmpty {
            return "Bearer \(v)"
        }
        return nil
    }

    /// Static `httpHeaders` merged with `envHttpHeaders` entries whose env var
    /// is set and non-empty.
    public func resolvedHeaders(env: [String: String]) -> [String: String] {
        var result = httpHeaders
        for (header, envVar) in envHttpHeaders {
            if let v = env[envVar], !v.isEmpty {
                result[header] = v
            }
        }
        return result
    }

    private func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// `baseURL` (trailing "/" trimmed) + `/responses` + sorted query params.
    public func responsesURL() -> String {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        var url = base + "/responses"
        if !queryParams.isEmpty {
            let parts = queryParams.sorted { $0.key < $1.key }.map { k, v in
                "\(k)=\(percentEncode(v))"
            }
            url += "?" + parts.joined(separator: "&")
        }
        return url
    }
}

/// Minimal config value mirroring `ConfigValue` so registry loading needs no
/// Config dependency (single-value Codable container, JSONLite pattern).
public enum ConfigValueLite: Sendable, Equatable, Codable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case object([String: ConfigValueLite])
    case array([ConfigValueLite])
    case null

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .string(let s): return Int64(s)
        default: return nil
        }
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var objectValue: [String: ConfigValueLite]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var arrayValue: [ConfigValueLite]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .int(Int64(d)); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ConfigValueLite].self) {
            self = .array(a); return
        }
        if let o = try? c.decode([String: ConfigValueLite].self) {
            self = .object(o); return
        }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported ConfigValueLite")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

/// Registry of providers (Codex `model_providers` map). Always includes the
/// built-in `openai` provider unless overridden by config.
public struct ModelProviderRegistry: Sendable {
    public let providers: [String: ModelProvider]

    public init(_ providers: [String: ModelProvider] = ["openai": .openAI]) {
        self.providers = providers
    }

    public func resolve(_ id: String?) -> ModelProvider {
        if let id, let p = providers[id] { return p }
        return providers["openai"] ?? .openAI
    }

    public func defaultProvider() -> ModelProvider {
        providers["openai"] ?? .openAI
    }

    private static func stringMap(_ v: ConfigValueLite?) -> [String: String] {
        guard let obj = v?.objectValue else { return [:] }
        var m: [String: String] = [:]
        for (k, val) in obj {
            if let s = val.stringValue { m[k] = s }
        }
        return m
    }

    /// Build a registry from a config object.
    ///
    /// Throws `ModelProviderConfigError.chatWireApiRemoved` if any provider
    /// sets `wire_api = "chat"` — upstream rejects that string at deserialise
    /// time (`CHAT_WIRE_API_REMOVED_ERROR`).
    public static func load(
        from configObject: [String: ConfigValueLite]
    ) throws -> ModelProviderRegistry {
        var result: [String: ModelProvider] = ["openai": .openAI]
        if let mp = configObject["model_providers"]?.objectValue {
            for (key, value) in mp {
                guard let obj = value.objectValue else { continue }
                let name = obj["name"]?.stringValue ?? key
                let baseURL = obj["base_url"]?.stringValue
                    ?? obj["baseURL"]?.stringValue ?? ""
                let envKey = obj["env_key"]?.stringValue
                    ?? obj["envKey"]?.stringValue
                let bearer = obj["experimental_bearer_token"]?.stringValue
                let wireApiRaw = obj["wire_api"]?.stringValue ?? "responses"
                if wireApiRaw == "chat" {
                    throw ModelProviderConfigError
                        .chatWireApiRemoved(providerId: key)
                }
                guard let wireApi = WireApi(rawValue: wireApiRaw) else {
                    throw ModelProviderConfigError
                        .unknownWireApi(providerId: key, value: wireApiRaw)
                }
                let queryParams = stringMap(obj["query_params"])
                let httpHeaders = stringMap(obj["http_headers"])
                let envHttpHeaders = stringMap(obj["env_http_headers"])
                let retries = obj["request_max_retries"]?.intValue
                    .map { Int($0) } ?? 4
                let requiresAuth = obj["requires_openai_auth"]?.boolValue
                    ?? false
                let supportsWs = obj["supports_websockets"]?.boolValue ?? false
                result[key] = ModelProvider(
                    id: key, name: name, baseURL: baseURL,
                    envKey: envKey, experimentalBearerToken: bearer,
                    wireApi: wireApi, queryParams: queryParams,
                    httpHeaders: httpHeaders, envHttpHeaders: envHttpHeaders,
                    requestMaxRetries: retries,
                    requiresOpenAIAuth: requiresAuth,
                    supportsWebsockets: supportsWs)
            }
        }
        return ModelProviderRegistry(result)
    }

    public static func load(fromJSON data: Data) throws -> ModelProviderRegistry {
        let dec = JSONDecoder()
        guard let obj = try? dec.decode(
            [String: ConfigValueLite].self, from: data) else {
            return ModelProviderRegistry()
        }
        return try load(from: obj)
    }

    /// Convenience non-throwing variant: returns the built-in default
    /// registry on any error. Use only at call sites where the alternative is
    /// silently dropping the user-configured providers (e.g. internal status
    /// queries that must not fail). Prefer the throwing `load(from:)` when
    /// the error can be surfaced to the user.
    public static func loadOrDefault(
        from configObject: [String: ConfigValueLite]
    ) -> ModelProviderRegistry {
        (try? load(from: configObject)) ?? ModelProviderRegistry()
    }
}

// MARK: - Telemetry

public struct UsageSnapshot: Sendable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    /// Subset of `outputTokens` attributable to model reasoning (OpenAI
    /// `output_tokens_details.reasoning_tokens`). Parity with upstream
    /// `TokenUsage.reasoning_output_tokens`. Zero for providers that don't
    /// surface the breakdown.
    public var reasoningOutputTokens: Int
    public var totalTokens: Int
    public init(inputTokens: Int = 0,
                cachedInputTokens: Int = 0,
                outputTokens: Int = 0,
                reasoningOutputTokens: Int = 0,
                totalTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct RateLimitWindow: Sendable, Equatable {
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetAt: String?
    public init(usedPercent: Double,
                windowMinutes: Int? = nil,
                resetAt: String? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetAt = resetAt
    }
}

public struct RateLimitSnapshot: Sendable, Equatable {
    public var limitId: String?
    public var limitName: String?
    public var primary: RateLimitWindow?
    public var secondary: RateLimitWindow?
    public init(limitId: String? = nil,
                limitName: String? = nil,
                primary: RateLimitWindow? = nil,
                secondary: RateLimitWindow? = nil) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
    }

    /// Parse the `x-<limitId>-{primary,secondary}-*` / `-limit-name` header
    /// family out of a curl `-D` header dump. Header names are lowercased
    /// (values preserved); last duplicate wins.
    public static func parseRateLimits(
        headerDump: String, limitId: String = "codex"
    ) -> RateLimitSnapshot? {
        var map: [String: String] = [:]
        for rawLine in headerDump.split(
            whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            map[name] = value
        }
        let prefix = ("x-" + limitId.replacingOccurrences(
            of: "_", with: "-")).lowercased()

        func window(_ kind: String) -> RateLimitWindow? {
            guard let upStr = map["\(prefix)-\(kind)-used-percent"],
                  let up = Double(upStr) else { return nil }
            let wm = map["\(prefix)-\(kind)-window-minutes"]
                .flatMap { Int($0) }
            let ra = map["\(prefix)-\(kind)-reset-at"]
            return RateLimitWindow(
                usedPercent: up, windowMinutes: wm, resetAt: ra)
        }

        let primary = window("primary")
        let secondary = window("secondary")
        let limitName = map["\(prefix)-limit-name"]
        if primary == nil && secondary == nil && limitName == nil {
            return nil
        }
        return RateLimitSnapshot(
            limitId: limitId, limitName: limitName,
            primary: primary, secondary: secondary)
    }
}

/// Records the last observed usage + rate-limit snapshot (Codex telemetry).
public actor UsageTracker {
    private var _lastUsage: UsageSnapshot?
    private var _lastRateLimits: RateLimitSnapshot?
    public init() {}
    public func recordUsage(_ u: UsageSnapshot) { _lastUsage = u }
    public func recordRateLimits(_ r: RateLimitSnapshot) {
        _lastRateLimits = r
    }
    public func lastUsage() -> UsageSnapshot? { _lastUsage }
    public func lastRateLimits() -> RateLimitSnapshot? { _lastRateLimits }
}
