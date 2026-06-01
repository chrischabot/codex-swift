import Foundation
import WireProtocol

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
    /// Per-event SSE idle timeout: the maximum time the Responses stream may
    /// stay silent between events before it is aborted with a retryable
    /// "idle timeout waiting for SSE" error. Mirrors upstream
    /// `ModelProviderInfo::stream_idle_timeout` (codex-api provider.rs:49),
    /// which the responses SSE loop wraps each `stream.next()` poll with
    /// (responses.rs:410-434). Upstream's config default is 300_000 ms / 5m
    /// (`stream_idle_timeout_ms`, config_tests.rs:7536).
    public var streamIdleTimeout: Duration

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
                supportsWebsockets: Bool = false,
                streamIdleTimeout: Duration = .seconds(300)) {
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
        self.streamIdleTimeout = streamIdleTimeout
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

    /// True when the provider's `name` is exactly `"OpenAI"`
    /// (`ModelProviderInfo::is_openai` — `self.name == OPENAI_PROVIDER_NAME`).
    public var isOpenAI: Bool { name == "OpenAI" }

    /// Faithful port of `codex-api::is_azure_responses_provider`: the provider
    /// name is `azure` (case-insensitive) OR the base URL contains one of the
    /// Azure Responses markers.
    public var isAzureResponsesProvider: Bool {
        if name.lowercased() == "azure" { return true }
        let lower = baseURL.lowercased()
        let markers = ["openai.azure.", "cognitiveservices.azure.",
                       "aoai.azure.", "azure-api.", "azurefd.",
                       "windows.net/openai"]
        return markers.contains { lower.contains($0) }
    }

    /// Faithful port of `ModelProviderInfo::supports_remote_compaction`:
    /// `is_openai() || is_azure_responses_provider(...)`. Gates whether the
    /// session uses the server-side `/responses/compact` endpoint instead of
    /// local prompt-driven compaction.
    public var supportsRemoteCompaction: Bool {
        isOpenAI || isAzureResponsesProvider
    }

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

/// One rate-limit window. Mirrors upstream `RateLimitWindow`
/// (`codex-protocol`): `resets_at` is an `Option<i64>` (a unix timestamp),
/// NOT a string.
public struct RateLimitWindow: Sendable, Equatable {
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetAt: Int64?
    public init(usedPercent: Double,
                windowMinutes: Int? = nil,
                resetAt: Int64? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetAt = resetAt
    }
}

/// Credits telemetry parsed from the `x-codex-credits-*` header family.
/// Mirrors upstream `CreditsSnapshot` (`codex-protocol`).
public struct CreditsSnapshot: Sendable, Equatable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?
    public init(hasCredits: Bool, unlimited: Bool, balance: String? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct RateLimitSnapshot: Sendable, Equatable {
    public var limitId: String?
    public var limitName: String?
    public var primary: RateLimitWindow?
    public var secondary: RateLimitWindow?
    /// Credits telemetry (`x-codex-credits-*`). Mirrors upstream
    /// `RateLimitSnapshot.credits`.
    public var credits: CreditsSnapshot?
    /// Plan type (`x-codex-plan-type`). Mirrors upstream
    /// `RateLimitSnapshot.plan_type`.
    public var planType: String?
    public init(limitId: String? = nil,
                limitName: String? = nil,
                primary: RateLimitWindow? = nil,
                secondary: RateLimitWindow? = nil,
                credits: CreditsSnapshot? = nil,
                planType: String? = nil) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.planType = planType
    }

    /// Serializes this snapshot into the v2 `RateLimitSnapshot` wire shape
    /// (`app-server-protocol/src/protocol/v2/account.rs:257-265`,
    /// camelCase, every field `Option` → emitted as `null` when absent). This
    /// is the payload carried by the `account/rateLimits/updated` notification
    /// (`AccountRateLimitsUpdatedNotification.rate_limits`). `used_percent` is
    /// rounded to an integer to match `RateLimitWindow::from` (`account.rs:347`).
    public func asNotificationJSON() -> JSONValue {
        func window(_ w: RateLimitWindow?) -> JSONValue {
            guard let w else { return .null }
            return .object([
                "usedPercent": .int(Int64(w.usedPercent.rounded())),
                "windowDurationMins": w.windowMinutes
                    .map { JSONValue.int(Int64($0)) } ?? .null,
                "resetsAt": w.resetAt.map { JSONValue.int($0) } ?? .null,
            ])
        }
        func creditsJSON(_ c: CreditsSnapshot?) -> JSONValue {
            guard let c else { return .null }
            return .object([
                "hasCredits": .bool(c.hasCredits),
                "unlimited": .bool(c.unlimited),
                "balance": c.balance.map(JSONValue.string) ?? .null,
            ])
        }
        return .object([
            "limitId": limitId.map(JSONValue.string) ?? .null,
            "limitName": limitName.map(JSONValue.string) ?? .null,
            "primary": window(primary),
            "secondary": window(secondary),
            "credits": creditsJSON(credits),
            "planType": planType.map(JSONValue.string) ?? .null,
            "rateLimitReachedType": .null,
        ])
    }

    /// Parse a curl `-D` header dump into a lowercased name→value map. Last
    /// duplicate wins (matches curl's accumulation order). Shared by the
    /// single-family and all-families parsers.
    private static func headerMap(_ headerDump: String) -> [String: String] {
        var map: [String: String] = [:]
        // NOTE: split on Unicode *scalars*, not Characters. In Swift a `\r\n`
        // sequence forms a single extended grapheme cluster (Character), so a
        // `Character`-based `$0 == "\n" || $0 == "\r"` separator never matches a
        // CRLF — which is exactly what real HTTP header dumps (`curl -D`,
        // `HTTPURLResponse.allHeaderFields` re-serialized as `"k: v\r\n"`) use.
        // Splitting on scalars handles both LF and CRLF line endings.
        for rawLine in headerDump.unicodeScalars.split(
            whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(String.UnicodeScalarView(rawLine))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            map[name] = value
        }
        return map
    }

    /// Normalizes a limit id the way upstream `normalize_limit_id` does:
    /// trim, lowercase, and replace `-` with `_`.
    private static func normalizeLimitId(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func parseCredits(_ map: [String: String]) -> CreditsSnapshot? {
        func boolHeader(_ name: String) -> Bool? {
            guard let raw = map[name] else { return nil }
            let lower = raw.lowercased()
            if lower == "true" || raw == "1" { return true }
            if lower == "false" || raw == "0" { return false }
            return nil
        }
        guard let hasCredits = boolHeader("x-codex-credits-has-credits"),
              let unlimited = boolHeader("x-codex-credits-unlimited") else {
            return nil
        }
        let balance = map["x-codex-credits-balance"]?
            .trimmingCharacters(in: .whitespaces)
        return CreditsSnapshot(
            hasCredits: hasCredits, unlimited: unlimited,
            balance: (balance?.isEmpty == false) ? balance : nil)
    }

    /// Parse rate-limit headers for a single limit family. `limitId` matches
    /// the server-provided metered limit id (e.g. `codex`, `codex_secondary`).
    /// Mirrors `parse_rate_limit_for_limit` — applies the per-window
    /// `has_data` gate so a bare `used_percent: 0` header does NOT yield a
    /// window.
    public static func parseRateLimits(
        headerDump: String, limitId: String = "codex"
    ) -> RateLimitSnapshot? {
        let map = headerMap(headerDump)
        let normalized = limitId.trimmingCharacters(in: .whitespaces).isEmpty
            ? "codex" : limitId
        let prefix = ("x-" + normalized.lowercased()
            .replacingOccurrences(of: "_", with: "-"))

        func window(_ kind: String) -> RateLimitWindow? {
            guard let upStr = map["\(prefix)-\(kind)-used-percent"],
                  let up = Double(upStr), up.isFinite else { return nil }
            let wm = map["\(prefix)-\(kind)-window-minutes"]
                .flatMap { Int64($0) }
            let ra = map["\(prefix)-\(kind)-reset-at"]
                .flatMap { Int64($0) }
            // Upstream `parse_rate_limit_window` has_data gate: emit only when
            // used_percent != 0, window_minutes != 0, or resets_at present.
            let hasData = up != 0.0
                || (wm != nil && wm != 0)
                || ra != nil
            guard hasData else { return nil }
            return RateLimitWindow(
                usedPercent: up,
                windowMinutes: wm.map { Int($0) },
                resetAt: ra)
        }

        let primary = window("primary")
        let secondary = window("secondary")
        let limitName = map["\(prefix)-limit-name"]?
            .trimmingCharacters(in: .whitespaces)
        let credits = parseCredits(map)
        // Upstream `parse_rate_limit_for_limit` (`rate_limits.rs:88-97`) always
        // sets `plan_type: None` on a header-derived snapshot; plan_type is
        // only populated by `parse_rate_limit_event` from the
        // `codex.rate_limits` SSE payload. We mirror that: do NOT read an
        // `x-codex-plan-type` header here, and do NOT include plan_type in the
        // has_data presence gate (primary/secondary/limitName/credits only).
        if primary == nil && secondary == nil
            && (limitName?.isEmpty != false)
            && credits == nil {
            return nil
        }
        return RateLimitSnapshot(
            limitId: normalizeLimitId(normalized),
            limitName: (limitName?.isEmpty == false) ? limitName : nil,
            primary: primary, secondary: secondary,
            credits: credits,
            planType: nil)
    }

    /// Discover every metered limit family present in the header dump and
    /// return a snapshot per family. Mirrors upstream `parse_all_rate_limits`:
    /// the default `codex` family first, then every other family discovered
    /// via an `x-<limit>-primary-used-percent` header, each gated by
    /// `has_rate_limit_data` (primary/secondary/credits present).
    public static func parseAllRateLimits(
        headerDump: String
    ) -> [RateLimitSnapshot] {
        let map = headerMap(headerDump)
        var snapshots: [RateLimitSnapshot] = []
        // Upstream `parse_rate_limit_for_limit` ALWAYS returns
        // `Some(RateLimitSnapshot{ .. })` for the default `codex` family even
        // when every window/credit field is None (rate_limits.rs:89), and
        // `parse_all_rate_limits` pushes it unconditionally (rate_limits.rs:27-31).
        // The `has_rate_limit_data` gate (rate_limits.rs:44-47) applies ONLY to
        // additional discovered families. So the result is never empty: with no
        // rate-limit headers it is exactly one all-None `codex` snapshot
        // (test parse_all_rate_limits_includes_default_codex_snapshot).
        if let def = parseRateLimits(headerDump: headerDump, limitId: "codex") {
            snapshots.append(def)
        } else {
            snapshots.append(RateLimitSnapshot(
                limitId: "codex", limitName: nil,
                primary: nil, secondary: nil,
                credits: nil, planType: nil))
        }
        // Discover families from `x-<limit>-primary-used-percent` headers.
        var limitIds = Set<String>()
        for name in map.keys {
            let suffix = "-primary-used-percent"
            guard name.hasSuffix(suffix) else { continue }
            let prefix = String(name.dropLast(suffix.count))
            guard prefix.hasPrefix("x-") else { continue }
            let limit = normalizeLimitId(String(prefix.dropFirst(2)))
            if limit != "codex" { limitIds.insert(limit) }
        }
        for limitId in limitIds.sorted() {
            guard let snap = parseRateLimits(
                headerDump: headerDump, limitId: limitId) else { continue }
            // has_rate_limit_data gate.
            if snap.primary != nil || snap.secondary != nil
                || snap.credits != nil {
                snapshots.append(snap)
            }
        }
        return snapshots
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
