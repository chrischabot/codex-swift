import Foundation
import Config
import Connectors
import EgressGuard

/// The composition-root gate + construction for the Google pack — a pure helper
/// (library, not executable) so both daemons share it and it is unit-testable.
/// Deny-default: returns nil unless `[features].google` is on AND a
/// `[connectors.google]` table with a client_id is present.
public enum GoogleWiring {
    /// Build the REST client from `[connectors.google]` tokens — shared by the
    /// `google_api` tool pack AND the #5 Gmail channel (both ride the SAME
    /// connected account). Gated on the connector table only (NOT `[features].google`,
    /// which is the *tool* gate): a channel can use Google without advertising the
    /// tool. nil when no `[connectors.google]` is configured. REST egress (host
    /// containment, redirect-off, dot-segment rejection) is enforced inside
    /// GoogleAPIClient via URLSessionGoogleHTTPClient; OAuth via EgressGuard.
    public static func makeAPIClient(addonConfig: Config, codexHome: String, env: [String: String]) -> GoogleAPIClient? {
        guard let cfg = GoogleConnectorConfig.read(from: addonConfig, codexHome: codexHome, env: env) else { return nil }
        let connector = cfg.makeConnector(egress: GoogleConnectorConfig.oauthEgress(),
                                          http: URLSessionOAuthHTTPClient(), env: env)
        return GoogleAPIClient(connector: connector, http: URLSessionGoogleHTTPClient())
    }

    public static func toolPack(addonConfig: Config, codexHome: String, env: [String: String]) -> GoogleToolPack? {
        guard addonConfig.isFeatureEnabled("google", env: env) else { return nil }
        guard let client = makeAPIClient(addonConfig: addonConfig, codexHome: codexHome, env: env) else { return nil }
        return GoogleToolPack(client: client)
    }
}
