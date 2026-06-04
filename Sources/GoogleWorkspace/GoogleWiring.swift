import Foundation
import Config
import Connectors
import EgressGuard

/// The composition-root gate + construction for the Google pack — a pure helper
/// (library, not executable) so both daemons share it and it is unit-testable.
/// Deny-default: returns nil unless `[features].google` is on AND a
/// `[connectors.google]` table with a client_id is present.
public enum GoogleWiring {
    public static func toolPack(addonConfig: Config, codexHome: String, env: [String: String]) -> GoogleToolPack? {
        guard addonConfig.isFeatureEnabled("google", env: env) else { return nil }
        guard let cfg = GoogleConnectorConfig.read(from: addonConfig, codexHome: codexHome, env: env) else { return nil }
        let connector = cfg.makeConnector(egress: GoogleConnectorConfig.oauthEgress(),
                                          http: URLSessionOAuthHTTPClient(), env: env)
        // REST egress (host containment, redirect-off, dot-segment rejection) is
        // enforced inside GoogleAPIClient via URLSessionGoogleHTTPClient.
        let client = GoogleAPIClient(connector: connector, http: URLSessionGoogleHTTPClient())
        return GoogleToolPack(client: client)
    }
}
