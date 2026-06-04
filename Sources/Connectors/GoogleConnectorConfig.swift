import Foundation
import Config
import EgressGuard

/// Reads `[connectors.google]` and builds the OAuth client / connector. A pure,
/// testable factory (lives in the library, not the executable, so the gate is
/// unit-testable). Deny-default: returns nil when `client_id` is absent.
public struct GoogleConnectorConfig: Sendable, Equatable {
    public let clientId: String
    /// The NAME of the env var holding the (web-client) secret — never the secret
    /// itself, never persisted.
    public let clientSecretEnvVar: String?
    public let scopes: [String]
    public let tokenStorePath: String

    /// Default Workspace read scopes (read-only is the safe baseline; writes are
    /// approval-gated in the tool regardless).
    public static let defaultScopes = [
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
    ]

    public init(clientId: String, clientSecretEnvVar: String?, scopes: [String], tokenStorePath: String) {
        self.clientId = clientId
        self.clientSecretEnvVar = clientSecretEnvVar
        self.scopes = scopes
        self.tokenStorePath = tokenStorePath
    }

    /// Read `[connectors.google]`. nil → not configured (deny-default).
    public static func read(from config: Config, codexHome: String, env: [String: String]) -> GoogleConnectorConfig? {
        guard let obj = config.value("connectors.google")?.objectValue,
              let clientId = obj["client_id"]?.stringValue, !clientId.isEmpty else { return nil }
        // ConfigValue has no `arrayValue` — pattern-match `.array` (Config.swift).
        var scopes = defaultScopes
        if case .array(let a)? = obj["scopes"] {
            let parsed = a.compactMap { $0.stringValue }
            if !parsed.isEmpty { scopes = parsed }
        }
        let secretEnv = obj["client_secret_env"]?.stringValue
        let tokenPath = (obj["token_store_path"]?.stringValue).map { expandHome($0, codexHome) }
            ?? (codexHome + "/connectors/google/tokens.json")
        return GoogleConnectorConfig(clientId: clientId, clientSecretEnvVar: secretEnv,
                                     scopes: scopes, tokenStorePath: tokenPath)
    }

    /// The config layer does NOT expand `$CODEX_HOME`; do it here.
    static func expandHome(_ p: String, _ codexHome: String) -> String {
        p.replacingOccurrences(of: "$CODEX_HOME", with: codexHome)
    }

    /// The OAuth EgressGuard is pinned to EXACTLY the token/revoke host
    /// (accounts.google.com is only the browser authorizationURL and is never
    /// fetched by the client). REST host containment is enforced separately in
    /// GoogleAPIClient.
    public static func oauthEgress() -> EgressGuard {
        EgressGuard(EgressPolicy(allowedHosts: ["oauth2.googleapis.com"]))
    }

    public func makeOAuthClient(egress: EgressGuard, http: any OAuthHTTPClient, env: [String: String]) -> GoogleOAuthClient {
        let secret = clientSecretEnvVar.flatMap { env[$0] }   // resolved at runtime, never stored
        let cfg = GoogleOAuthConfig(clientId: clientId, clientSecret: secret, scopes: scopes)
        return GoogleOAuthClient(config: cfg, egress: egress, http: http)
    }

    public func makeConnector(egress: EgressGuard, http: any OAuthHTTPClient, env: [String: String]) -> GoogleConnector {
        GoogleConnector(client: makeOAuthClient(egress: egress, http: http, env: env),
                        store: FileTokenStore(path: tokenStorePath))
    }
}
