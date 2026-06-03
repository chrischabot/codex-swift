import XCTest
import Foundation
@testable import EgressGuard

/// Severe tests for ADDONS.md Phase 0 #5 — the egress chokepoint (SSRF defense:
/// HTTPS-only, host allowlist, IP-range blocking incl. post-DNS rebinding).
final class EgressGuardTests: XCTestCase {

    /// Guard with a fixed resolver (so DNS rebinding is deterministic).
    private func guardResolving(_ ips: [String], allowedHosts: Set<String> = [],
                                allowHTTP: Bool = false) -> EgressGuard {
        EgressGuard(EgressPolicy(allowedHosts: allowedHosts, allowHTTP: allowHTTP,
                                 resolve: { _ in ips }))
    }

    private func assertDenied(_ d: EgressDecision, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(d.isAllowed, msg.isEmpty ? "expected deny, got \(d)" : msg, file: file, line: line)
    }

    // MARK: scheme

    func testHTTPRejectedByDefault() {
        let g = guardResolving(["1.1.1.1"])
        assertDenied(g.validate(urlString: "http://example.com/x"))
    }

    func testHTTPAllowedWhenPolicyPermitsButIPStillChecked() {
        let pub = EgressGuard(EgressPolicy(allowHTTP: true, resolve: { _ in ["1.1.1.1"] }))
        XCTAssertTrue(pub.validate(urlString: "http://example.com/x").isAllowed)
        // ...but http to a private IP is still blocked
        assertDenied(pub.validate(urlString: "http://10.0.0.1/x"))
    }

    func testNonHTTPSchemeDenied() {
        let g = guardResolving(["1.1.1.1"])
        assertDenied(g.validate(urlString: "file:///etc/passwd"))
        assertDenied(g.validate(urlString: "gopher://x/"))
    }

    // MARK: IP-literal SSRF targets

    func testCloudMetadataBlocked() {
        let g = guardResolving([])
        assertDenied(g.validate(urlString: "https://169.254.169.254/latest/meta-data/"))
    }

    func testLoopbackBlocked() {
        let g = guardResolving([])
        assertDenied(g.validate(urlString: "https://127.0.0.1/"))
        assertDenied(g.validate(urlString: "https://127.1.2.3/"))
        assertDenied(g.validate(urlString: "https://[::1]/"))
    }

    func testPrivateAndLinkLocalRangesBlocked() {
        let g = guardResolving([])
        for h in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                  "169.254.10.10", "100.64.0.1", "0.0.0.0", "[fc00::1]", "[fe80::1]"] {
            assertDenied(g.validate(urlString: "https://\(h)/"), "expected \(h) blocked")
        }
    }

    func testV4MappedV6LoopbackBlocked() {
        let g = guardResolving([])
        assertDenied(g.validate(urlString: "https://[::ffff:127.0.0.1]/"))
    }

    func testPublicIPLiteralsAllowed() {
        let g = guardResolving([])
        XCTAssertTrue(g.validate(urlString: "https://1.1.1.1/").isAllowed)
        XCTAssertTrue(g.validate(urlString: "https://172.32.0.1/").isAllowed)   // just outside 172.16/12
        XCTAssertTrue(g.validate(urlString: "https://[2606:4700:4700::1111]/").isAllowed)
    }

    // MARK: URL tricks

    func testCredentialsInURLDenied() {
        let g = guardResolving(["1.1.1.1"])
        assertDenied(g.validate(urlString: "https://user:pass@example.com/"))
        assertDenied(g.validate(urlString: "https://victim@169.254.169.254/"))
    }

    func testInternalTLDDenied() {
        let g = guardResolving(["1.1.1.1"])
        assertDenied(g.validate(urlString: "https://metadata.internal/"))
    }

    // MARK: allowlist

    func testAllowlistEnforced() {
        let g = guardResolving(["1.1.1.1"], allowedHosts: ["api.example.com"])
        assertDenied(g.validate(urlString: "https://evil.com/"))
        XCTAssertTrue(g.validate(urlString: "https://api.example.com/v1").isAllowed)
    }

    // MARK: DNS rebinding (the resolved IP, not the name, decides)

    func testDNSRebindingToPrivateDenied() {
        // An allowlisted name that resolves to an internal IP must be denied.
        let g = guardResolving(["10.0.0.5"], allowedHosts: ["api.example.com"])
        assertDenied(g.validate(urlString: "https://api.example.com/"))
    }

    func testAnyResolvedIPBlockedDenies() {
        // Mixed result: one public, one loopback → deny (defeats split-horizon).
        let g = guardResolving(["1.2.3.4", "127.0.0.1"])
        assertDenied(g.validate(urlString: "https://example.com/"))
    }

    func testUnresolvableHostDenied() {
        let g = guardResolving([])   // resolves to nothing
        assertDenied(g.validate(urlString: "https://does-not-resolve.example/"))
    }

    func testResolvedPublicAllowed() {
        let g = guardResolving(["93.184.216.34"])
        XCTAssertTrue(g.validate(urlString: "https://example.com/").isAllowed)
    }

    // MARK: IP classifier unit checks

    func testParseAndClassify() {
        XCTAssertEqual(ParsedIP.parse("8.8.8.8"), .v4([8, 8, 8, 8]))
        XCTAssertTrue(ParsedIP.parse("10.255.255.255")!.isBlocked)
        XCTAssertFalse(ParsedIP.parse("11.0.0.1")!.isBlocked)
        XCTAssertTrue(ParsedIP.parse("::1")!.isBlocked)
        XCTAssertNil(ParsedIP.parse("not-an-ip"))
    }

    // MARK: v2 — alternate IPv4 encodings (parser-confusion SSRF)

    func testOctalLeadingZeroIPv4Denied() {
        let g = guardResolving(["1.1.1.1"])   // resolver would say public IF it reached resolve
        assertDenied(g.validate(urlString: "https://0177.0.0.1/"), "octal 0177 == 127 loopback to inet_aton")
        assertDenied(g.validate(urlString: "https://0012.0.0.1/"))
    }

    func testHexIPv4Denied() {
        let g = guardResolving(["1.1.1.1"])
        assertDenied(g.validate(urlString: "https://0x7f.0.0.1/"))
    }

    func testDecimalIntegerAndShortFormIPv4Denied() {
        let g = guardResolving(["1.1.1.1"])
        assertDenied(g.validate(urlString: "https://2130706433/"), "decimal-integer 127.0.0.1")
        assertDenied(g.validate(urlString: "https://127.1/"), "short-form 127.0.0.1")
    }

    // MARK: v2 — IPv6 embedded-v4 forms

    func testNAT64EmbeddedV4Blocked() {
        let g = guardResolving([])
        assertDenied(g.validate(urlString: "https://[64:ff9b::a9fe:a9fe]/"), "NAT64 metadata")
        assertDenied(g.validate(urlString: "https://[64:ff9b::7f00:1]/"), "NAT64 loopback")
    }

    func testV4CompatibleAndSixToFourBlocked() {
        let g = guardResolving([])
        assertDenied(g.validate(urlString: "https://[::127.0.0.1]/"), "v4-compatible loopback")
        assertDenied(g.validate(urlString: "https://[::a9fe:a9fe]/"), "v4-compatible metadata")
        assertDenied(g.validate(urlString: "https://[2002:7f00:1::]/"), "6to4 loopback")
    }

    // MARK: v2 — host canonicalization

    func testTrailingDotInternalDenied() {
        let g = guardResolving(["1.1.1.1"])
        assertDenied(g.validate(urlString: "https://foo.internal./"))
    }

    func testAllowlistCaseAndTrailingDotCanonicalized() {
        let g = guardResolving(["1.1.1.1"], allowedHosts: ["api.example.com"])
        XCTAssertTrue(g.validate(urlString: "https://API.Example.com./v1").isAllowed,
                      "uppercase + trailing dot canonicalize to the allowlisted host")
        assertDenied(g.validate(urlString: "https://evil.com/"))
    }

    func testBenchmarkingRangeBlocked() {
        let g = guardResolving([])
        assertDenied(g.validate(urlString: "https://198.18.0.1/"))
    }

    // MARK: v2 — connect-bound: pinned IPs + peer check

    func testVetReturnsPinnedIPsForHostname() {
        let g = guardResolving(["1.2.3.4", "5.6.7.8"])
        guard case let .allow(approval) = g.vet(URL(string: "https://example.com/")!) else {
            return XCTFail("expected allow")
        }
        XCTAssertEqual(approval.pinnedIPs, ["1.2.3.4", "5.6.7.8"],
                       "the caller must connect to (pin) the vetted IPs to defeat rebinding")
    }

    func testVetPinsTheLiteralForAnIPHost() {
        let g = guardResolving([])
        guard case let .allow(approval) = g.vet(URL(string: "https://1.1.1.1/")!) else {
            return XCTFail("expected allow")
        }
        XCTAssertEqual(approval.pinnedIPs, ["1.1.1.1"])
    }

    func testIsPeerAllowedEnforcesAtConnectTime() {
        let g = guardResolving([])
        XCTAssertTrue(g.isPeerAllowed("1.1.1.1"))
        XCTAssertFalse(g.isPeerAllowed("127.0.0.1"), "a rebinding answer caught at connect time")
        XCTAssertFalse(g.isPeerAllowed("169.254.169.254"))
        XCTAssertFalse(g.isPeerAllowed("10.0.0.1"))
        XCTAssertFalse(g.isPeerAllowed("garbage"))
    }

    // MARK: v2.1 — codex-round fixes

    /// A resolver that returns an AMBIGUOUS/unparseable IP form fails CLOSED
    /// (a connect path could read 0177.0.0.1 as octal loopback).
    func testResolverReturningAmbiguousIPDenied() {
        let g = guardResolving(["0177.0.0.1"])   // octal-looking → strict parse fails
        assertDenied(g.validate(urlString: "https://evil.example.com/"))
        let g2 = guardResolving(["0x7f.0.0.1"])
        assertDenied(g2.validate(urlString: "https://evil2.example.com/"))
    }

    /// A real hostname that merely CONTAINS "0x" is NOT denied (it has non-hex
    /// letters → treated as a hostname, resolved normally).
    func testHostnameContaining0xIsAllowed() {
        let g = guardResolving(["93.184.216.34"])
        XCTAssertTrue(g.validate(urlString: "https://0xcdn.example.com/").isAllowed)
    }

    /// All-hex-looking hostnames whose labels are still HOSTNAME labels (a
    /// letter-led label exists) must resolve, not be denied — but a single
    /// all-numeric/hex label IS ambiguous (inet_aton would read it as an IP).
    func testAllHexHostnamesResolvedButSingleNumericLabelDenied() {
        let g = guardResolving(["93.184.216.34"])
        XCTAssertTrue(g.validate(urlString: "https://deadbeef.cab/").isAllowed)
        XCTAssertTrue(g.validate(urlString: "https://0xcafe.cab/").isAllowed,
                      "the 'cab' label starts with a letter → hostname")
        assertDenied(g.validate(urlString: "https://0xdeadbeef/"),
                     "a single numeric/hex label is an ambiguous IP form")
    }

    /// `EgressApproval.allows(peerIP:)` enforces pin membership (the real
    /// rebinding defense), stronger than the public-only `isPeerAllowed`.
    func testApprovalAllowsPinMembership() {
        let g = guardResolving(["1.2.3.4", "5.6.7.8"])
        guard case let .allow(approval) = g.vet(URL(string: "https://example.com/")!) else {
            return XCTFail("expected allow")
        }
        XCTAssertTrue(approval.allows(peerIP: "1.2.3.4"))
        XCTAssertFalse(approval.allows(peerIP: "9.9.9.9"), "a peer NOT among the vetted pins is rejected")
    }
}
