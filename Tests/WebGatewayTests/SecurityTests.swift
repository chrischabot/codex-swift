import XCTest
@testable import WebGateway

final class SecurityPolicyTests: XCTestCase {
    private func authPolicy(origins: Set<String> = []) -> SecurityPolicy {
        SecurityPolicy(enforceMethodAllowlist: true, requireAuth: true,
                       bearerToken: "s3cret-token", allowedOrigins: origins)
    }

    // MARK: Origin

    func testOriginUserinfoSpoofRejected() {
        // The critical bypass: URL.host after `user@` would parse to 127.0.0.1.
        let p = authPolicy()
        XCTAssertFalse(p.originAllowed("http://evil.com@127.0.0.1:8443"))
        XCTAssertFalse(p.originAllowed("https://attacker@localhost"))
    }

    func testOriginLoopbackAllowed() {
        let p = authPolicy()
        XCTAssertTrue(p.originAllowed("https://127.0.0.1:8443"))
        XCTAssertTrue(p.originAllowed("http://localhost:5173"))
    }

    func testOriginForeignRejected() {
        XCTAssertFalse(authPolicy().originAllowed("https://evil.example.com"))
    }

    func testMissingOriginRejectedWhenAuth() {
        XCTAssertFalse(authPolicy().originAllowed(nil))
        XCTAssertFalse(authPolicy().originAllowed(""))
    }

    func testMissingOriginAllowedOnLoopbackDev() {
        let p = SecurityPolicy(requireAuth: false)
        XCTAssertTrue(p.originAllowed(nil))
    }

    func testOriginAllowlistMatch() {
        let p = authPolicy(origins: ["https://app.example.com"])
        XCTAssertTrue(p.originAllowed("https://app.example.com"))
        XCTAssertFalse(p.originAllowed("https://other.com"))
        // userinfo still rejected even if host is in the allowlist
        XCTAssertFalse(p.originAllowed("https://x@app.example.com"))
    }

    // MARK: Host (anti DNS-rebind)

    func testHostMatchesBind() {
        XCTAssertTrue(authPolicy().hostAllowed("127.0.0.1:8443", bindHost: "127.0.0.1"))
        XCTAssertTrue(authPolicy().hostAllowed("[::1]:8443", bindHost: "127.0.0.1"))
    }

    func testHostRebindRejected() {
        XCTAssertFalse(authPolicy().hostAllowed("evil.example.com", bindHost: "127.0.0.1"))
    }

    func testHostAllowlistMatch() {
        let p = authPolicy(origins: ["https://app.example.com"])
        XCTAssertTrue(p.hostAllowed("app.example.com:443", bindHost: "0.0.0.0"))
    }

    // MARK: Bearer

    func testBearerSubprotocolAccept() {
        let p = authPolicy()
        XCTAssertTrue(p.bearerAccepted(subprotocols: ["bearer.s3cret-token"], authorization: nil))
        XCTAssertFalse(p.bearerAccepted(subprotocols: ["bearer.wrong"], authorization: nil))
    }

    func testBearerHeaderAccept() {
        let p = authPolicy()
        XCTAssertTrue(p.bearerAccepted(subprotocols: [], authorization: "Bearer s3cret-token"))
        XCTAssertFalse(p.bearerAccepted(subprotocols: [], authorization: "Bearer nope"))
        XCTAssertFalse(p.bearerAccepted(subprotocols: [], authorization: nil))
    }

    func testBearerDisabledWhenNoAuth() {
        XCTAssertTrue(SecurityPolicy(requireAuth: false).bearerAccepted(subprotocols: [], authorization: nil))
    }

    func testHttpBearerHelper() {
        XCTAssertTrue(authPolicy().httpBearerAccepted("Bearer s3cret-token"))
        XCTAssertFalse(authPolicy().httpBearerAccepted("Bearer x"))
    }

    // MARK: constant-time compare

    func testConstantTimeEqual() {
        XCTAssertTrue(SecurityPolicy.constantTimeEqual("abc123", "abc123"))
        XCTAssertFalse(SecurityPolicy.constantTimeEqual("abc123", "abc124"))
        XCTAssertFalse(SecurityPolicy.constantTimeEqual("abc", "abcd"))
        XCTAssertTrue(SecurityPolicy.constantTimeEqual("", ""))
    }

    func testSafeHostRejectsUserinfo() {
        XCTAssertNil(SecurityPolicy.safeHost("http://a@b.com"))
        XCTAssertEqual(SecurityPolicy.safeHost("https://b.com:8443"), "b.com")
    }
}

final class MethodGateTests: XCTestCase {
    func testAllowsUIMethods() {
        for m in ["initialize", "thread/list", "thread/start", "thread/resume",
                  "turn/start", "turn/interrupt", "thread/name/set", "thread/archive"] {
            XCTAssertTrue(MethodGate.isAllowed(m), "expected \(m) allowed")
        }
    }

    func testDeniesPrivilegedMethods() {
        // Still deny-default: direct exec/spawn, fs writes/removes, login/logout,
        // and unknown methods are NOT reachable from the web UI.
        for m in ["command/exec", "process/spawn", "fs/writeFile", "fs/remove",
                  "account/login", "account/logout", "config/write", "bogus/method"] {
            XCTAssertFalse(MethodGate.isAllowed(m), "expected \(m) denied")
        }
    }

    func testAllowsFullUISurface() {
        // The single-tenant UI deliberately reaches these (config writes, account
        // reads, git/automations/pin, remote-control + environment enrollment).
        for m in ["model/list", "config/value/write", "account/read", "thread/pin/set",
                  "git/action", "automation/action", "thread/goal/set", "thread/shellCommand",
                  "remoteControl/enable", "environment/add", "thread/realtime/start"] {
            XCTAssertTrue(MethodGate.isAllowed(m), "expected \(m) allowed for full UI")
        }
    }

    // MARK: owner/write tier (audit — a flat single bearer let any token holder write/spend)

    func testEffectfulMethodsAreOwnerTierAndStillAllowed() {
        for m in ["wiki/page/upsert", "wiki/page/delete", "wiki/page/rename",
                  "wiki/research/start", "wiki/ingest/start", "config/value/write",
                  "config/batchWrite", "remoteControl/enable", "remoteControl/disable",
                  "environment/add", "plugin/install", "plugin/uninstall"] {
            XCTAssertTrue(MethodGate.requiresOwner(m), "\(m) must be owner-tier")
            XCTAssertTrue(MethodGate.isAllowed(m), "owner-tier is a strict subset of Tier-A allowed")
        }
    }

    func testPureReadsAreNotOwnerTier() {
        for m in ["wiki/list", "wiki/page/get", "wiki/search", "wiki/graph",
                  "wiki/librarian/report", "wiki/sessions/list", "thread/list", "account/read"] {
            XCTAssertFalse(MethodGate.requiresOwner(m), "\(m) is a read — stays Tier-A only")
        }
    }

    func testOwnerCredentialIsADistinctSecretFromReadBearer() {
        var p = SecurityPolicy(requireAuth: true, bearerToken: "read-bearer")
        p.ownerToken = "owner-secret"
        // THE seam: the READ bearer must NOT unlock the owner tier.
        XCTAssertFalse(p.ownerAccepted(subprotocols: ["bearer.read-bearer"], authorization: "Bearer read-bearer"),
                       "a leaked read bearer can browse but not write/spend")
        // The owner secret is accepted via header AND via the owner.<token> subprotocol.
        XCTAssertTrue(p.ownerAccepted(subprotocols: [], authorization: "Bearer owner-secret"))
        XCTAssertTrue(p.ownerAccepted(subprotocols: ["owner.owner-secret"], authorization: nil))
        XCTAssertFalse(p.ownerAccepted(subprotocols: ["owner.wrong"], authorization: "Bearer wrong"))
    }

    func testOwnerTierFailsClosedWithoutAToken() {
        let p = SecurityPolicy(requireAuth: true, bearerToken: "read-bearer")   // no ownerToken set
        XCTAssertFalse(p.ownerAccepted(subprotocols: ["owner.anything"], authorization: "Bearer anything"),
                       "no configured owner token ⇒ the tier is unreachable (fail-closed)")
    }
}
