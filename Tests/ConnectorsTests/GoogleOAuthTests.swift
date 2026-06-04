import XCTest
import Foundation
@testable import Connectors
@testable import EgressGuard
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Severe tests for the ADDONS #3 Google OAuth runtime: PKCE (RFC 7636 vector),
/// auth-URL building, token exchange/refresh/revoke (with EgressGuard SSRF
/// denial), the connector's transparent refresh, the callback parser (CSRF
/// state + error handling), and a real loopback-socket round trip.
final class GoogleOAuthTests: XCTestCase {

    private func egressAllowAll() -> EgressGuard {
        EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: true, resolve: { _ in ["93.184.216.34"] }))
    }
    private func egressDenyAll() -> EgressGuard {
        EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: true, resolve: { _ in ["127.0.0.1"] }))
    }
    private func cfg(tokenEndpoint: String = "https://oauth2.googleapis.com/token",
                     revokeEndpoint: String = "https://oauth2.googleapis.com/revoke") -> GoogleOAuthConfig {
        GoogleOAuthConfig(clientId: "cid.apps.googleusercontent.com",
                          scopes: ["https://www.googleapis.com/auth/drive.readonly"],
                          tokenEndpoint: tokenEndpoint, revokeEndpoint: revokeEndpoint)
    }

    // MARK: PKCE

    func testPKCERFC7636Vector() {
        // RFC 7636 Appendix B.
        let challenge = PKCE.s256Challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEGenerateIsURLSafeAndUnique() {
        let a = PKCE.generate(), b = PKCE.generate()
        XCTAssertNotEqual(a.verifier, b.verifier, "fresh verifier each time")
        for s in [a.verifier, a.challenge] {
            XCTAssertFalse(s.contains("+") || s.contains("/") || s.contains("="), "url-safe, unpadded")
            XCTAssertFalse(s.isEmpty)
        }
        XCTAssertEqual(a.method, "S256")
    }

    // MARK: auth URL

    func testAuthorizationURL() {
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: StubOAuthHTTP())
        let url = client.authorizationURL(redirectURI: "http://127.0.0.1:5500/oauth2/callback",
                                          state: "STATE123", pkce: PKCE(verifier: "v", challenge: "CH"))
        let s = url?.absoluteString ?? ""
        for needle in ["client_id=cid", "code_challenge=CH", "code_challenge_method=S256",
                       "state=STATE123", "access_type=offline", "response_type=code",
                       "redirect_uri=http"] {
            XCTAssertTrue(s.contains(needle), "auth URL missing \(needle): \(s)")
        }
    }

    // MARK: token exchange / refresh / revoke

    func testExchangeParsesTokens() async {
        let http = StubOAuthHTTP(body: #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"scope":"s","token_type":"Bearer"}"#)
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: http, now: { 1000 })
        let r = await client.exchange(code: "CODE", verifier: "VER", redirectURI: "http://127.0.0.1/cb")
        guard case .success(let t) = r else { return XCTFail("exchange failed: \(r)") }
        XCTAssertEqual(t.accessToken, "AT")
        XCTAssertEqual(t.refreshToken, "RT")
        XCTAssertEqual(t.expiresAt, 1000 + 3600)
        // the form carried code, verifier, grant_type
        let fields = await http.lastFields()
        XCTAssertEqual(fields?["code"], "CODE")
        XCTAssertEqual(fields?["code_verifier"], "VER")
        XCTAssertEqual(fields?["grant_type"], "authorization_code")
    }

    func testExchangeEgressDenied() async {
        let client = GoogleOAuthClient(config: cfg(), egress: egressDenyAll(), http: StubOAuthHTTP())
        let r = await client.exchange(code: "C", verifier: "V", redirectURI: "x")
        guard case .failure(.egressDenied) = r else { return XCTFail("SSRF-vetted token endpoint must deny: \(r)") }
    }

    func testRefreshCarriesOldRefreshToken() async {
        // Google omits refresh_token on refresh — the client must keep the old one.
        let http = StubOAuthHTTP(body: #"{"access_token":"AT2","expires_in":3600,"token_type":"Bearer"}"#)
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: http, now: { 2000 })
        let r = await client.refresh(refreshToken: "RT-OLD")
        guard case .success(let t) = r else { return XCTFail("refresh failed: \(r)") }
        XCTAssertEqual(t.accessToken, "AT2")
        XCTAssertEqual(t.refreshToken, "RT-OLD", "refresh carries the existing refresh token")
        XCTAssertEqual(t.expiresAt, 2000 + 3600)
    }

    func testRevokeSuccess() async {
        let http = StubOAuthHTTP(status: 200)
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: http)
        let r = await client.revoke(token: "RT")
        guard case .success = r else { return XCTFail("revoke should succeed on 200") }
        let fields = await http.lastFields()
        XCTAssertEqual(fields?["token"], "RT")
    }

    // MARK: connector (transparent refresh)

    func testConnectorReturnsValidToken() async {
        let store = MemoryTokenStore(OAuthTokens(accessToken: "AT", refreshToken: "RT", expiresAt: 10_000, scope: "", tokenType: "Bearer"))
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: StubOAuthHTTP(), now: { 5000 })
        let conn = GoogleConnector(client: client, store: store, now: { 5000 })
        let r = await conn.accessToken()
        XCTAssertEqual(try? r.get(), "AT", "a non-expired token is returned without refreshing")
    }

    func testConnectorRefreshesExpiredToken() async {
        let store = MemoryTokenStore(OAuthTokens(accessToken: "OLD", refreshToken: "RT", expiresAt: 4000, scope: "", tokenType: "Bearer"))
        let http = StubOAuthHTTP(body: #"{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}"#)
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: http, now: { 5000 })
        let conn = GoogleConnector(client: client, store: store, now: { 5000 })
        let r = await conn.accessToken()
        XCTAssertEqual(try? r.get(), "NEW", "an expired token is transparently refreshed")
        // and persisted
        let saved = await store.load()
        XCTAssertEqual(saved?.accessToken, "NEW")
        XCTAssertEqual(saved?.refreshToken, "RT", "refresh token preserved across refresh")
    }

    func testConnectorRevokeAndClear() async {
        let store = MemoryTokenStore(OAuthTokens(accessToken: "AT", refreshToken: "RT", expiresAt: 9999, scope: "", tokenType: "Bearer"))
        let http = StubOAuthHTTP(status: 200)
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: http)
        let conn = GoogleConnector(client: client, store: store)
        let ok = await conn.revokeAndClear()
        XCTAssertTrue(ok)
        let after = await store.load()
        XCTAssertNil(after, "tokens cleared after revoke")
    }

    func testConnectorNoTokensFails() async {
        let store = MemoryTokenStore(nil)
        let client = GoogleOAuthClient(config: cfg(), egress: egressAllowAll(), http: StubOAuthHTTP())
        let conn = GoogleConnector(client: client, store: store)
        let r = await conn.accessToken()
        guard case .failure(.noRefreshToken) = r else { return XCTFail("unauthorized must fail noRefreshToken") }
    }

    // MARK: callback parsing (CSRF)

    func testParseCallbackHappy() {
        let r = LoopbackRedirectServer.parseCallback(
            "GET /oauth2/callback?code=ABC123&state=S1 HTTP/1.1\r\nHost: x\r\n\r\n",
            path: "/oauth2/callback", expectedState: "S1")
        XCTAssertEqual(try? r.get(), "ABC123")
    }

    func testParseCallbackStateMismatch() {
        let r = LoopbackRedirectServer.parseCallback(
            "GET /oauth2/callback?code=ABC&state=WRONG HTTP/1.1\r\n\r\n",
            path: "/oauth2/callback", expectedState: "S1")
        guard case .failure(.stateMismatch) = r else { return XCTFail("CSRF state mismatch must be rejected") }
    }

    func testParseCallbackError() {
        let r = LoopbackRedirectServer.parseCallback(
            "GET /oauth2/callback?error=access_denied&state=S1 HTTP/1.1\r\n\r\n",
            path: "/oauth2/callback", expectedState: "S1")
        guard case .failure(.callbackError(let e)) = r else { return XCTFail("error param must surface") }
        XCTAssertEqual(e, "access_denied")
    }

    func testParseCallbackWrongPath() {
        let r = LoopbackRedirectServer.parseCallback(
            "GET /evil?code=ABC&state=S1 HTTP/1.1\r\n\r\n",
            path: "/oauth2/callback", expectedState: "S1")
        guard case .failure(.callbackError) = r else { return XCTFail("an unexpected path must be rejected") }
    }

    // MARK: loopback integration (real socket)

    func testLoopbackServerRoundTrip() async throws {
        let server = LoopbackRedirectServer()
        let uri = try await server.start()
        let port = await server.port
        XCTAssertTrue(uri.hasPrefix("http://127.0.0.1:"), "binds loopback on an ephemeral port: \(uri)")
        XCTAssertGreaterThan(port, 0)
        async let result = server.awaitCallback(expectedState: "S1", timeoutMs: 4000)
        try? await Task.sleep(for: .milliseconds(30))   // let the accept loop start
        Self.clientGET(port: port, target: "/oauth2/callback?code=THE-CODE&state=S1")
        let r = await result
        await server.stop()
        XCTAssertEqual(try? r.get(), "THE-CODE", "the loopback server returns the auth code from a real connection")
    }

    /// Open a loopback TCP connection and send a one-line GET.
    static func clientGET(port: Int, target: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return }
        let req = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        let bytes = Array(req.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        // drain the response so the server's write doesn't SIGPIPE.
        var buf = [UInt8](repeating: 0, count: 1024)
        _ = read(fd, &buf, buf.count)
    }
}

// MARK: fixtures

actor StubOAuthHTTP: OAuthHTTPClient {
    private let status: Int
    private let body: Data
    private var _lastFields: [String: String]?
    init(status: Int = 200, body: String = #"{"access_token":"AT","expires_in":3600,"token_type":"Bearer"}"#) {
        self.status = status
        self.body = Data(body.utf8)
    }
    func postForm(url: URL, fields: [String: String]) async -> Result<(status: Int, body: Data), OAuthError> {
        _lastFields = fields
        return .success((status: status, body: body))
    }
    func lastFields() -> [String: String]? { _lastFields }
}
