import XCTest
import Foundation
@testable import Gmail
@testable import Channels
@testable import GoogleWorkspace
@testable import Connectors
@testable import EgressGuard

/// LIVE-TOKEN end-to-end for the Gmail channel SEND path against the real Gmail
/// API. It is **opt-in** and skips cleanly in CI: it runs only when
/// `GMAIL_LIVE_TEST=1` and a previously-connected account's token store is
/// pointed at via env. Setup (one-time, on the operator's machine):
///
///   1. Configure `[connectors.google]` with a `gmail.modify` scope and run
///      `codexd google-connect` to write the 0600 token file.
///   2. Export:
///        GMAIL_LIVE_TEST=1
///        GMAIL_LIVE_TOKEN_STORE=$CODEX_HOME/connectors/google/tokens.json
///        GMAIL_LIVE_CLIENT_ID=<id>.apps.googleusercontent.com
///        GMAIL_LIVE_SECRET_ENV=GOOGLE_OAUTH_CLIENT_SECRET   (name of the env var holding the secret)
///        GMAIL_LIVE_TO=you@example.com                       (a real inbox you control)
///   3. `swift test --filter GmailLiveTests`
///
/// The test sends one tagged email through the real API and asserts the send
/// succeeds. (Inbound poll-back is left manual — it depends on delivery latency
/// and would make the test flaky.)
final class GmailLiveTests: XCTestCase {

    func testLiveGmailSend() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GMAIL_LIVE_TEST"] == "1",
              let tokenStore = env["GMAIL_LIVE_TOKEN_STORE"], !tokenStore.isEmpty,
              let clientId = env["GMAIL_LIVE_CLIENT_ID"], !clientId.isEmpty,
              let to = env["GMAIL_LIVE_TO"], !to.isEmpty
        else { throw XCTSkip("Gmail live test not configured (set GMAIL_LIVE_TEST=1 + GMAIL_LIVE_* env)") }
        let secret = env["GMAIL_LIVE_SECRET_ENV"].flatMap { env[$0] }

        let oauth = GoogleOAuthClient(
            config: GoogleOAuthConfig(clientId: clientId, clientSecret: secret, scopes: []),
            egress: GoogleConnectorConfig.oauthEgress(),
            http: URLSessionOAuthHTTPClient())
        let connector = GoogleConnector(client: oauth, store: FileTokenStore(path: tokenStore))
        let api = GoogleAPIClient(connector: connector, http: URLSessionGoogleHTTPClient())
        let channel = GmailChannel(api: api, ownerEmails: [to.lowercased()], fromAddress: nil, pollMs: 2000)

        let tag = "codex-swift gmail live test \(UUID().uuidString)"
        let receipt = await channel.send(OutboundMessage(conversationId: to, text: tag))
        XCTAssertTrue(receipt.ok, "live Gmail send failed: \(receipt.detail) — check the gmail.modify/send scope is granted")
    }
}
