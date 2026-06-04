import Foundation
import Config

/// The one-time CONNECT routine (a `codexd google-connect` subcommand, NOT an
/// RPC — it must not stream the refresh-token secret over the control plane, and
/// it blocks on a browser round-trip + writes a 0600 token file). Dependency-
/// injected (`openURL`/`emit`) so it is testable. Returns a process exit code.
/// NEVER emits the code, verifier, access_token, or refresh_token.
public func runGoogleConnect(addonConfig: Config,
                             codexHome: String,
                             env: [String: String],
                             openURL: @Sendable (URL) -> Void,
                             emit: @Sendable (String) -> Void) async -> Int32 {
    guard let cfg = GoogleConnectorConfig.read(from: addonConfig, codexHome: codexHome, env: env) else {
        emit("google-connect: add a [connectors.google] table with client_id to your config first\n")
        return 78   // EX_CONFIG
    }
    let oauth = cfg.makeOAuthClient(egress: GoogleConnectorConfig.oauthEgress(),
                                    http: URLSessionOAuthHTTPClient(), env: env)
    let server = LoopbackRedirectServer()
    let redirectURI: String
    do { redirectURI = try await server.start() }
    catch { emit("google-connect: could not start the loopback server: \(error)\n"); return 70 }

    let state = PKCE.randomURLSafe(byteCount: 24)
    let pkce = PKCE.generate()
    guard let url = oauth.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce) else {
        await server.stop()
        emit("google-connect: could not build the authorization URL\n")
        return 70
    }
    emit("Open this URL in your browser to authorize Google access:\n\(url.absoluteString)\n")
    openURL(url)

    let codeResult = await server.awaitCallback(expectedState: state, timeoutMs: 300_000)
    await server.stop()
    let code: String
    switch codeResult {
    case .success(let c): code = c
    case .failure(let e): emit("google-connect: authorization callback failed: \(e)\n"); return 1
    }

    switch await oauth.exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI) {
    case .success(let tokens):
        await FileTokenStore(path: cfg.tokenStorePath).save(tokens)
        emit("google-connect: connected. token saved (scopes: \(tokens.scope))\n")
        return 0
    case .failure(let e):
        emit("google-connect: token exchange failed: \(e)\n")
        return 1
    }
}

/// Revoke the grant + clear the local token (the `google-disconnect` sibling).
public func runGoogleDisconnect(addonConfig: Config,
                                codexHome: String,
                                env: [String: String],
                                emit: @Sendable (String) -> Void) async -> Int32 {
    guard let cfg = GoogleConnectorConfig.read(from: addonConfig, codexHome: codexHome, env: env) else {
        emit("google-disconnect: no [connectors.google] configured\n")
        return 78
    }
    let connector = cfg.makeConnector(egress: GoogleConnectorConfig.oauthEgress(),
                                      http: URLSessionOAuthHTTPClient(), env: env)
    let ok = await connector.revokeAndClear()
    emit(ok ? "google-disconnect: revoked + cleared\n"
            : "google-disconnect: local token cleared (remote revoke may have failed)\n")
    return 0
}
