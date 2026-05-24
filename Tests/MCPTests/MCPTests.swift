import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives

final class MCPTests: XCTestCase {

    func testJSONLiteRoundTripAndEscaping() throws {
        let data = Data(#"{"a":"x\ny","b":[1,true,null],"c":{"k\"q":2}}"#.utf8)
        let v = try JSONLite.parse(data)
        guard case .object(let o) = v else { return XCTFail("object") }
        XCTAssertEqual(o["a"], .string("x\ny"))
        guard case .array(let arr)? = o["b"] else { return XCTFail("array") }
        XCTAssertEqual(arr, [.number(1), .bool(true), .null])
        // Stringify must escape control chars + keys (JSONSerialization-backed).
        let s = JSONLite.stringify(.object(["k\"q": .string("a\nb")]))
        XCTAssertTrue(s.contains("\\n"))
        XCTAssertTrue(s.contains("k\\\"q"))
        // Re-parse to confirm validity.
        _ = try JSONLite.parse(Data(s.utf8))
    }

    func testLoadConfigsFromMcpJson() {
        let home = NSTemporaryDirectory() + "mcp-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let json = """
        { "servers": [ { "name": "fs", "command": "mcp-fs", "args": ["--root","/"] } ] }
        """
        try? json.write(toFile: home + "/mcp.json", atomically: true, encoding: .utf8)
        let cfgs = McpManager.loadConfigs(codexHome: home)
        XCTAssertEqual(cfgs.count, 1)
        XCTAssertEqual(cfgs[0].name, "fs")
        XCTAssertEqual(cfgs[0].args, ["--root", "/"])
        XCTAssertTrue(McpManager.loadConfigs(codexHome: "/nope-\(UUID())").isEmpty)
    }

    /// Standard upstream codex shape: `[mcp_servers.<name>]` tables inside
     /// `$CODEX_HOME/config.toml`. The Swift implementation must parse this
     /// path natively (parity finding F1) so users following the canonical
     /// codex docs get their MCP servers loaded.
    func testLoadConfigsFromConfigTomlMcpServersTable() throws {
        let home = NSTemporaryDirectory() + "mcp-toml-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        [mcp_servers.test]
        command = "cat"
        args    = ["foo"]
        env     = { MY_KEY = "val" }

        [mcp_servers.remote]
        url                  = "https://example.com/mcp"
        bearer_token_env_var = "MY_BEARER"
        http_headers         = { X-Custom = "header" }
        """
        try? toml.write(toFile: home + "/config.toml",
                        atomically: true, encoding: .utf8)
        let cfgs = McpManager.loadConfigs(codexHome: home)
        XCTAssertGreaterThanOrEqual(cfgs.count, 1)
        guard let test = cfgs.first(where: { $0.name == "test" }) else {
            return XCTFail("expected 'test' server in config.toml")
        }
        XCTAssertEqual(test.command, "cat")
        XCTAssertEqual(test.args, ["foo"])
        XCTAssertEqual(test.env?["MY_KEY"], "val")
        XCTAssertFalse(test.isHTTP)

        let remote = try XCTUnwrap(cfgs.first(where: { $0.name == "remote" }),
                                   "HTTP server not loaded from config.toml")
        XCTAssertTrue(remote.isHTTP)
        XCTAssertEqual(remote.url, "https://example.com/mcp")
        XCTAssertEqual(remote.bearerTokenEnvVar, "MY_BEARER")
        XCTAssertEqual(remote.httpHeaders["X-Custom"], "header")
    }

    /// When `config.toml` has no `[mcp_servers]` table (or is absent), the
    /// loader must still pick up legacy `$CODEX_HOME/mcp.json` so existing
    /// users don't lose their configuration when this PR lands.
    func testLoadConfigsFallsBackToMcpJson() {
        let home = NSTemporaryDirectory() + "mcp-fallback-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // config.toml with no [mcp_servers] — must not shadow mcp.json.
        let toml = """
        model = "gpt-5.1-codex"
        """
        try? toml.write(toFile: home + "/config.toml",
                        atomically: true, encoding: .utf8)
        let json = """
        { "mcpServers": { "fs": { "command": "mcp-fs", "args": ["--root","/"] } } }
        """
        try? json.write(toFile: home + "/mcp.json",
                        atomically: true, encoding: .utf8)
        let cfgs = McpManager.loadConfigs(codexHome: home)
        XCTAssertEqual(cfgs.count, 1)
        XCTAssertEqual(cfgs[0].name, "fs")
        XCTAssertEqual(cfgs[0].command, "mcp-fs")
        XCTAssertEqual(cfgs[0].args, ["--root", "/"])
    }

    /// When the same name appears in both config.toml and mcp.json,
    /// config.toml wins (parity with upstream where config.toml is the
    /// canonical source). Names only in mcp.json are still loaded so a
    /// partial migration works.
    func testLoadConfigsMergesTomlOverJson() {
        let home = NSTemporaryDirectory() + "mcp-merge-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        [mcp_servers.shared]
        command = "from-toml"
        args    = ["a"]
        """
        try? toml.write(toFile: home + "/config.toml",
                        atomically: true, encoding: .utf8)
        let json = """
        { "mcpServers": {
            "shared": { "command": "from-json" },
            "only-json": { "command": "leftover" }
        } }
        """
        try? json.write(toFile: home + "/mcp.json",
                        atomically: true, encoding: .utf8)
        let cfgs = McpManager.loadConfigs(codexHome: home)
        XCTAssertEqual(cfgs.count, 2)
        let shared = cfgs.first(where: { $0.name == "shared" })
        XCTAssertEqual(shared?.command, "from-toml")
        XCTAssertEqual(shared?.args, ["a"])
        let only = cfgs.first(where: { $0.name == "only-json" })
        XCTAssertEqual(only?.command, "leftover")
    }

    func testToolProxyNamespacing() async {
        let client = McpClient(McpServerConfig(name: "srv", command: "/bin/true"))
        let proxy = McpToolProxy(server: "srv", tool: "do_thing", client: client)
        XCTAssertEqual(proxy.name, "mcp__srv__do_thing")
        XCTAssertTrue(proxy.parallelSafe)
    }

    /// End-to-end stdio JSON-RPC against a scripted mock MCP server. The mock
    /// is written in python3 and flushes stdout after every response: a POSIX
    /// shell builtin `printf` block-buffers stdout to a pipe and `stdbuf`
    /// cannot change a builtin's buffering, so a shell mock never replies
    /// interactively. python3 is available on Linux and macOS and `McpClient`
    /// resolves the bare `python3` command through `/usr/bin/env`.
    func testStdioRoundTripAgainstMockServer() async throws {
        let dir = NSTemporaryDirectory() + "mcpsrv-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
        // Reads JSON-RPC lines; replies by method; flushes each response so
        // the client's reader sees it immediately. Ignores the initialized
        // notification.
        let body = #"""
        import sys, json
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            s = line.strip()
            if not s:
                continue
            try:
                msg = json.loads(s)
            except Exception:
                continue
            m = msg.get("method"); i = msg.get("id")
            if m == "initialize":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":"2025-06-18"}}), flush=True)
            elif m == "notifications/initialized":
                pass
            elif m == "tools/list":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"tools":[{"name":"echo","description":"echoes","inputSchema":{"type":"object"}}]}}), flush=True)
            elif m == "tools/call":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":"pong"}],"isError":False}}), flush=True)
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        let client = McpClient(McpServerConfig(name: "mock", command: "python3",
                                               args: [script]),
                               requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map { $0.name }, ["echo"])
        let r = try await client.callTool("echo", argumentsJSON: "{\"x\":1}")
        XCTAssertEqual(r.text, "pong")
        XCTAssertFalse(r.isError)
        await client.stop()
    }

    // MARK: - P7.1 / H-46 upstream parity for McpServerConfig fields

    /// All 12+ upstream-only fields must decode from a single config.toml
    /// `[mcp_servers.<name>]` table. This locks in the exhaustive shape
    /// surface so a regression in any single field (e.g. forgetting
    /// `env_http_headers` again) fails this single assertion-heavy test.
    func testMcpServerConfigDecodesAllUpstreamFields() {
        let home = NSTemporaryDirectory() + "mcp-allfields-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        [mcp_servers.full]
        command = "myserver"
        args    = ["--flag"]
        env     = { A = "1" }
        env_vars = ["PATH", { name = "REMOTE_TOKEN", source = "remote" }]
        cwd     = "/workspace"
        startup_timeout_sec = 15
        tool_timeout_sec    = 200
        required = true
        supports_parallel_tool_calls = true
        enabled_tools  = ["alpha", "beta"]
        disabled_tools = ["gamma"]
        scopes         = ["read", "write"]
        oauth_resource = "https://api.example.com"

        [mcp_servers.full.oauth]
        client_id = "abc-123"

        [mcp_servers.remote]
        url              = "https://example.com/mcp"
        bearer_token_env_var = "MY_BEARER"
        http_headers     = { X-Custom = "header" }
        env_http_headers = { X-Token = "TOKEN_ENV_VAR" }
        startup_timeout_sec = 5
        tool_timeout_sec    = 45
        scopes              = ["mcp.read"]
        """
        try? toml.write(toFile: home + "/config.toml",
                        atomically: true, encoding: .utf8)
        let cfgs = McpManager.loadConfigs(codexHome: home)
        guard let full = cfgs.first(where: { $0.name == "full" }) else {
            return XCTFail("expected 'full' server")
        }
        XCTAssertEqual(full.command, "myserver")
        XCTAssertEqual(full.args, ["--flag"])
        XCTAssertEqual(full.env?["A"], "1")
        XCTAssertEqual(full.cwd, "/workspace")
        XCTAssertEqual(full.envVars?.count, 2)
        XCTAssertEqual(full.envVars?[0].name, "PATH")
        XCTAssertNil(full.envVars?[0].source)
        XCTAssertEqual(full.envVars?[1].name, "REMOTE_TOKEN")
        XCTAssertEqual(full.envVars?[1].source, "remote")
        XCTAssertTrue(full.envVars?[1].isRemoteSource ?? false)
        XCTAssertEqual(full.startupTimeoutSec, 15)
        XCTAssertEqual(full.toolTimeoutSec, 200)
        XCTAssertEqual(full.effectiveToolTimeout, 200)
        XCTAssertEqual(full.required, true)
        XCTAssertEqual(full.supportsParallelToolCalls, true)
        XCTAssertEqual(full.enabledTools, ["alpha", "beta"])
        XCTAssertEqual(full.disabledTools, ["gamma"])
        XCTAssertEqual(full.scopes, ["read", "write"])
        XCTAssertEqual(full.oauthResource, "https://api.example.com")
        XCTAssertEqual(full.oauth?.clientId, "abc-123")

        guard let remote = cfgs.first(where: { $0.name == "remote" }) else {
            return XCTFail("expected 'remote' server")
        }
        XCTAssertTrue(remote.isHTTP)
        XCTAssertEqual(remote.url, "https://example.com/mcp")
        XCTAssertEqual(remote.bearerTokenEnvVar, "MY_BEARER")
        XCTAssertEqual(remote.httpHeaders["X-Custom"], "header")
        XCTAssertEqual(remote.envHttpHeaders?["X-Token"], "TOKEN_ENV_VAR")
        XCTAssertEqual(remote.startupTimeoutSec, 5)
        XCTAssertEqual(remote.toolTimeoutSec, 45)
        XCTAssertEqual(remote.scopes, ["mcp.read"])
    }

    /// Upstream's `tool_timeout_sec` default is **120 seconds**. We
    /// previously hardcoded 30s, which audit finding H-46 / area 04 F2
    /// flagged as a major-severity gap (long-running MCP tools failed
    /// 4x sooner than upstream).
    func testToolTimeoutDefaultIs120Seconds() {
        let stdio = McpServerConfig(name: "x", command: "y")
        XCTAssertNil(stdio.toolTimeoutSec)
        XCTAssertEqual(stdio.effectiveToolTimeout, 120,
                       "upstream default tool_timeout_sec must be 120s")
        XCTAssertEqual(McpServerConfig.defaultToolTimeoutSec, 120)

        let http = McpServerConfig(name: "h", url: "https://h")
        XCTAssertNil(http.toolTimeoutSec)
        XCTAssertEqual(http.effectiveToolTimeout, 120)

        // Explicit value wins.
        var override = stdio
        override.toolTimeoutSec = 60
        XCTAssertEqual(override.effectiveToolTimeout, 60)
    }

    /// Upstream's `startup_timeout_sec` default is **30 seconds**
    /// (`codex-mcp/src/rmcp_client.rs::DEFAULT_STARTUP_TIMEOUT` and the
    /// same value used in `codex-mcp/src/mcp/mod.rs:448`). The P7.1
    /// reviewer found we had previously hardcoded 10s, which would kill
    /// servers with slow cold starts (JVM, heavy Python deps) 3x too
    /// early. This test locks in the corrected default.
    func testStartupTimeoutDefaultIs30Seconds() {
        XCTAssertEqual(McpServerConfig.defaultStartupTimeoutSec, 30)

        let stdio = McpServerConfig(name: "x", command: "y")
        XCTAssertNil(stdio.startupTimeoutSec)
        XCTAssertEqual(stdio.effectiveStartupTimeout, 30,
                       "upstream default startup_timeout_sec must be 30s")

        let http = McpServerConfig(name: "h", url: "https://h")
        XCTAssertNil(http.startupTimeoutSec)
        XCTAssertEqual(http.effectiveStartupTimeout, 30)

        // Explicit value wins.
        var override = stdio
        override.startupTimeoutSec = 5
        XCTAssertEqual(override.effectiveStartupTimeout, 5)
    }

    /// `enabledTools` is an allowlist; `disabledTools` is a denylist
    /// applied after. Filtered tools must NOT reach the model. The Swift
    /// implementation applies the filter inside `McpManager.startAll`;
    /// we test the pure filter helper here so the test stays hermetic
    /// (no process / network).
    func testEnabledToolsFiltersToolSpecs() {
        let all: [McpToolSpec] = [
            McpToolSpec(name: "alpha", description: "", inputSchemaJSON: "{}"),
            McpToolSpec(name: "beta", description: "", inputSchemaJSON: "{}"),
            McpToolSpec(name: "gamma", description: "", inputSchemaJSON: "{}"),
        ]
        // No filters → identity.
        let none = McpServerConfig(name: "n", command: "x")
        XCTAssertEqual(none.filterTools(all).map { $0.name },
                       ["alpha", "beta", "gamma"])

        // Allowlist only.
        var allow = McpServerConfig(name: "a", command: "x")
        allow.enabledTools = ["alpha"]
        XCTAssertEqual(allow.filterTools(all).map { $0.name }, ["alpha"])

        // Denylist only.
        var deny = McpServerConfig(name: "d", command: "x")
        deny.disabledTools = ["beta"]
        XCTAssertEqual(deny.filterTools(all).map { $0.name },
                       ["alpha", "gamma"])

        // Allowlist then denylist (allow wins first, deny strips after).
        var both = McpServerConfig(name: "b", command: "x")
        both.enabledTools = ["alpha", "beta"]
        both.disabledTools = ["beta"]
        XCTAssertEqual(both.filterTools(all).map { $0.name }, ["alpha"])
    }

    /// `cwd` from config.toml must be set as the working directory of
    /// the spawned stdio server process. We can't intercept `Process`
    /// directly, so we use a python mock that emits its `os.getcwd()`
    /// in the tools/call response. The harness spawns the script with
    /// the configured `cwd` and we assert the round-trip text matches.
    func testCwdIsSetOnStdioServerSpawn() async throws {
        let scriptDir = NSTemporaryDirectory() + "mcpsrv-cwd-script-"
            + UUID().uuidString
        let workDir = NSTemporaryDirectory() + "mcpsrv-cwd-work-"
            + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: scriptDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            atPath: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: scriptDir)
            try? FileManager.default.removeItem(atPath: workDir)
        }
        let script = scriptDir + "/server.py"
        let body = #"""
        import sys, json, os
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            s = line.strip()
            if not s:
                continue
            try:
                msg = json.loads(s)
            except Exception:
                continue
            m = msg.get("method"); i = msg.get("id")
            if m == "initialize":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":"2025-06-18"}}), flush=True)
            elif m == "notifications/initialized":
                pass
            elif m == "tools/list":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"tools":[{"name":"pwd","description":"","inputSchema":{"type":"object"}}]}}), flush=True)
            elif m == "tools/call":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":os.getcwd()}],"isError":False}}), flush=True)
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        // Resolve symlinks so macOS's `/private/var` ↔ `/var` alias does
        // not break the equality assertion.
        let resolvedWorkDir = URL(fileURLWithPath: workDir)
            .resolvingSymlinksInPath().path
        var cfg = McpServerConfig(name: "cwd", command: "python3",
                                  args: [script])
        cfg.cwd = resolvedWorkDir
        let client = McpClient(cfg, requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()
        let r = try await client.callTool("pwd", argumentsJSON: "{}")
        XCTAssertFalse(r.isError)
        // Server reports `os.getcwd()`; should match the cwd we set.
        XCTAssertEqual(URL(fileURLWithPath: r.text).resolvingSymlinksInPath().path,
                       resolvedWorkDir)
        await client.stop()
    }

    /// Sanity: `env_http_headers` decodes correctly and is preserved on
    /// the config struct even for the HTTP transport. Actual header
    /// emission to curl is covered by inspecting the resolved value in
    /// the McpHttpClient code-path (see McpHttpTests for that test).
    func testEnvHttpHeadersDecodeForHttpServer() {
        let home = NSTemporaryDirectory() + "mcp-ehh-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        [mcp_servers.remote]
        url              = "https://example.com/mcp"
        env_http_headers = { X-Auth = "AUTH_VAR" }
        """
        try? toml.write(toFile: home + "/config.toml",
                        atomically: true, encoding: .utf8)
        let cfgs = McpManager.loadConfigs(codexHome: home)
        guard let remote = cfgs.first(where: { $0.name == "remote" }) else {
            return XCTFail("expected 'remote' server")
        }
        XCTAssertEqual(remote.envHttpHeaders?["X-Auth"], "AUTH_VAR")
    }
}