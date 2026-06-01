import XCTest
import Foundation
@testable import MCP
@testable import ProtocolModel
import WireProtocol

/// Targeted unit tests for the v13 MCP audit findings:
///   1. A configured `bearer_token_env_var` that is unset/empty fails startup
///      with the upstream `resolve_bearer_token` diagnostic, rather than
///      silently connecting unauthenticated.
///   2. `mcpServer/startupStatus/updated`-equivalent per-server progress is
///      surfaced via the startAll status callback (Starting → Ready/Failed).
///   5. MCP init-failure messages are curated (GitHub PAT guidance, login
///      hint, startup-timeout config hint) by `mcpInitErrorDisplay`.
///   6. The direct `callTool` path re-enforces the per-server enabled/disabled
///      tool filter at the call boundary.
final class McpFindingsV13Tests: XCTestCase {

    // A minimal client whose tool calls always "succeed" so the filter check
    // (which runs BEFORE dispatch) is the only thing that can reject a call.
    private actor StubClient: McpClientProtocol {
        func start() throws {}
        func initialize() async throws {}
        func listTools() async throws -> [McpToolSpec] { [] }
        func callTool(_ name: String, argumentsJSON: String, meta: [String: Any]?,
                      elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult {
            McpCallResult(text: "ok:\(name)", isError: false)
        }
        func readResource(uri: String) async throws -> [String: JSONLite] { [:] }
        func listResourcesPage(cursor: String?) async throws -> [String: JSONLite] { [:] }
        func listResourceTemplatesPage(cursor: String?) async throws -> [String: JSONLite] { [:] }
        func stop() async {}
    }

    // MARK: - Finding 1: bearer-token validation

    func testBearerTokenNotSetFailsStartup() {
        var cfg = McpServerConfig(name: "gh", url: "https://example.com/mcp/")
        cfg.bearerTokenEnvVar = "MY_TOKEN_THAT_IS_NOT_SET_XYZ"
        let err = McpManager.validateBearerToken(cfg, env: [:])
        XCTAssertEqual(err,
            "Environment variable MY_TOKEN_THAT_IS_NOT_SET_XYZ for MCP server 'gh' is not set")
    }

    func testBearerTokenEmptyFailsStartup() {
        var cfg = McpServerConfig(name: "gh", url: "https://example.com/mcp/")
        cfg.bearerTokenEnvVar = "MY_TOKEN"
        let err = McpManager.validateBearerToken(cfg, env: ["MY_TOKEN": ""])
        XCTAssertEqual(err,
            "Environment variable MY_TOKEN for MCP server 'gh' is empty")
    }

    func testBearerTokenPresentPasses() {
        var cfg = McpServerConfig(name: "gh", url: "https://example.com/mcp/")
        cfg.bearerTokenEnvVar = "MY_TOKEN"
        XCTAssertNil(McpManager.validateBearerToken(cfg, env: ["MY_TOKEN": "secret"]))
    }

    func testNoBearerTokenConfiguredSkipsValidation() {
        let cfg = McpServerConfig(name: "gh", url: "https://example.com/mcp/")
        XCTAssertNil(McpManager.validateBearerToken(cfg, env: [:]))
    }

    /// End-to-end: a server with an unresolvable bearer token must end up in
    /// the `failed` state (never connect) and emit a `failed` status update.
    func testStartAllFailsServerWithUnresolvableBearerToken() async {
        var cfg = McpServerConfig(name: "secured", url: "https://example.com/mcp/")
        cfg.bearerTokenEnvVar = "DEFINITELY_UNSET_ENV_VAR_FOR_TEST_Q"
        let mgr = McpManager()
        actor Collected { var items: [(String, McpServerStartupState, String?)] = []
            func add(_ s: String, _ st: McpServerStartupState, _ e: String?) {
                items.append((s, st, e)) } }
        let collected = Collected()
        await mgr.startAll(cfg.name == "" ? [] : [cfg]) { server, status, error in
            await collected.add(server, status, error)
        }
        let statuses = await mgr.statusList()
        XCTAssertEqual(statuses.first?.state, "failed")
        XCTAssertEqual(statuses.first?.error,
            "Environment variable DEFINITELY_UNSET_ENV_VAR_FOR_TEST_Q for MCP server 'secured' is not set")
        let items = await collected.items
        // Only a single `failed` update is emitted (no `starting` before it,
        // mirroring upstream which fails before the Starting transition).
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.1, .failed)
    }

    // MARK: - Finding 5: mcp_init_error_display

    func testGitHubMcpNoOauthGuidance() {
        let cfg = McpServerConfig(name: "github", url: McpManager.gitHubMcpURL)
        let msg = McpManager.mcpInitErrorDisplay(serverName: "github", config: cfg,
                                                 rawError: "connection refused")
        XCTAssertTrue(msg.contains("GitHub MCP does not support OAuth"), msg)
        XCTAssertTrue(msg.contains("personal access token"), msg)
        XCTAssertTrue(msg.contains("[mcp_servers.github]"), msg)
        XCTAssertTrue(msg.contains("bearer_token_env_var = CODEX_GITHUB_PERSONAL_ACCESS_TOKEN"), msg)
    }

    func testGitHubMcpWithBearerDoesNotShowOauthGuidance() {
        var cfg = McpServerConfig(name: "github", url: McpManager.gitHubMcpURL)
        cfg.bearerTokenEnvVar = "TOK"
        let msg = McpManager.mcpInitErrorDisplay(serverName: "github", config: cfg,
                                                 rawError: "Auth required")
        XCTAssertFalse(msg.contains("does not support OAuth"), msg)
        XCTAssertTrue(msg.contains("is not logged in"), msg)
    }

    func testAuthRequiredGuidance() {
        let cfg = McpServerConfig(name: "myserver", command: "x")
        let msg = McpManager.mcpInitErrorDisplay(serverName: "myserver", config: cfg,
                                                 rawError: "fatal: Auth required for endpoint")
        XCTAssertEqual(msg,
            "The myserver MCP server is not logged in. Run `codex mcp login myserver`.")
    }

    func testStartupTimeoutGuidance() {
        var cfg = McpServerConfig(name: "slow", command: "x")
        cfg.startupTimeoutSec = 45
        let msg = McpManager.mcpInitErrorDisplay(serverName: "slow", config: cfg,
                                                 rawError: "request timed out")
        XCTAssertTrue(msg.contains("MCP client for `slow` timed out after 45 seconds"), msg)
        XCTAssertTrue(msg.contains("startup_timeout_sec = XX"), msg)
    }

    func testStartupTimeoutHandshakeVariantGuidance() {
        let cfg = McpServerConfig(name: "slow", command: "x")  // default 30s
        let msg = McpManager.mcpInitErrorDisplay(serverName: "slow", config: cfg,
                                                 rawError: "timed out handshaking with MCP server")
        XCTAssertTrue(msg.contains("timed out after 30 seconds"), msg)
    }

    func testGenericFailureGuidance() {
        let cfg = McpServerConfig(name: "srv", command: "x")
        let msg = McpManager.mcpInitErrorDisplay(serverName: "srv", config: cfg,
                                                 rawError: "boom")
        XCTAssertEqual(msg, "MCP client for `srv` failed to start: boom")
    }

    // MARK: - Finding 6: callTool re-enforces the tool filter

    func testCallToolRejectsDisabledTool() async {
        var cfg = McpServerConfig(name: "srv", command: "x")
        cfg.disabledTools = ["danger"]
        let mgr = McpManager()
        await mgr._seedClientForTesting("srv", StubClient(), config: cfg)
        do {
            _ = try await mgr.callTool(server: "srv", tool: "danger", argumentsJSON: "{}")
            XCTFail("expected disabled-tool rejection")
        } catch let err as McpError {
            XCTAssertTrue(err.description.contains("tool 'danger' is disabled for MCP server 'srv'"), err.description)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testCallToolRejectsToolNotInEnabledAllowlist() async {
        var cfg = McpServerConfig(name: "srv", command: "x")
        cfg.enabledTools = ["safe"]
        let mgr = McpManager()
        await mgr._seedClientForTesting("srv", StubClient(), config: cfg)
        do {
            _ = try await mgr.callTool(server: "srv", tool: "other", argumentsJSON: "{}")
            XCTFail("expected allowlist rejection")
        } catch let err as McpError {
            XCTAssertTrue(err.description.contains("tool 'other' is disabled for MCP server 'srv'"), err.description)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testCallToolAllowsPermittedTool() async throws {
        var cfg = McpServerConfig(name: "srv", command: "x")
        cfg.enabledTools = ["safe"]
        let mgr = McpManager()
        await mgr._seedClientForTesting("srv", StubClient(), config: cfg)
        let r = try await mgr.callTool(server: "srv", tool: "safe", argumentsJSON: "{}")
        XCTAssertEqual(r.text, "ok:safe")
    }

    func testToolAllowedMatchesUpstreamSemantics() {
        // No allowlist, no denylist → allow everything.
        let none = McpServerConfig(name: "s", command: "x")
        XCTAssertTrue(none.toolAllowed("anything"))
        // Allowlist gates.
        var allow = McpServerConfig(name: "s", command: "x")
        allow.enabledTools = ["a", "b"]
        XCTAssertTrue(allow.toolAllowed("a"))
        XCTAssertFalse(allow.toolAllowed("c"))
        // Denylist subtracts, even from an allowlisted tool.
        var both = McpServerConfig(name: "s", command: "x")
        both.enabledTools = ["a", "b"]
        both.disabledTools = ["b"]
        XCTAssertTrue(both.toolAllowed("a"))
        XCTAssertFalse(both.toolAllowed("b"))
    }
}
