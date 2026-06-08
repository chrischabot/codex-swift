import XCTest
import Foundation
@testable import MCP

/// P7.3 / parity area 04 F6+F7+F8: stdio MCP servers must run with a
/// sanitized environment (`env_clear()` parity), in their own process
/// group (so SIGTERM-to-group cleans up grandchildren), and the
/// `McpOAuthStore` must be wired into `startAll` callers (codex-session,
/// codexd) instead of `nil`.
final class McpP73Tests: XCTestCase {

    // MARK: - F6: env_clear sanitization

    /// Sanity: the allowlist must contain PATH+HOME (so resolvers/tools
    /// still work) but must NOT include anything that could carry
    /// upstream-host secrets (api keys, oauth tokens, ssh agents).
    func testDefaultEnvAllowlistShape() {
        let allow = Set(McpClient.defaultEnvAllowlist)
        XCTAssertTrue(allow.contains("PATH"), "PATH must be inherited so /usr/bin/env can resolve commands")
        XCTAssertTrue(allow.contains("HOME"))
        let forbidden = [
            "CODEX_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY",
            "AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "SSH_AUTH_SOCK",
        ]
        for name in forbidden {
            XCTAssertFalse(allow.contains(name),
                           "default env allowlist must not leak \(name)")
        }
    }

    /// `buildStdioEnvironment` must drop unrelated parent vars even
    /// when no `env`/`envVars` are configured. This is the core F6
    /// regression guard — the previous impl left `p.environment` unset
    /// and inherited everything.
    func testBuildStdioEnvironmentDropsSecretsByDefault() {
        // Set a secret-shaped var on the parent process before we build
        // the child env. We poke it via setenv (Swift stdlib has no
        // mutate-env helper, but POSIX setenv is available via Glibc/Darwin
        // implicitly through Foundation in Swift).
        setenv("CODEX_API_KEY", "supersecret-MUST-NOT-LEAK", 1)
        defer { unsetenv("CODEX_API_KEY") }
        // Mutating the process-wide PATH leaks across tests; restore
        // whatever we inherited on the way out so later tests
        // (e.g. ShellToolTests' `sleep`-based timeout test, SpawnWorkerTests)
        // can still resolve `/bin/sleep` etc.
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        defer {
            if let p = originalPATH { setenv("PATH", p, 1) }
            else { unsetenv("PATH") }
        }
        setenv("PATH", "/usr/bin:/bin", 1)

        let cfg = McpServerConfig(name: "x", command: "echo", args: [])
        let env = try! McpClient.buildStdioEnvironment(config: cfg)
        XCTAssertNil(env["CODEX_API_KEY"],
                     "F6: parent secrets must NOT leak into stdio child env")
        XCTAssertNotNil(env["PATH"],
                        "PATH must still be forwarded so commands resolve")
    }

    /// `env_vars: ["FOO"]` opts FOO into the child env (locally sourced)
    /// while keeping the rest of the allowlist intact.
    func testBuildStdioEnvironmentForwardsExplicitEnvVars() {
        setenv("MY_EXPLICIT_OPT_IN", "opted-in-value", 1)
        defer { unsetenv("MY_EXPLICIT_OPT_IN") }
        setenv("MY_UNREQUESTED_SECRET", "do-not-leak", 1)
        defer { unsetenv("MY_UNREQUESTED_SECRET") }
        var cfg = McpServerConfig(name: "x", command: "echo")
        cfg.envVars = [McpServerEnvVar(name: "MY_EXPLICIT_OPT_IN")]
        let env = try! McpClient.buildStdioEnvironment(config: cfg)
        XCTAssertEqual(env["MY_EXPLICIT_OPT_IN"], "opted-in-value")
        XCTAssertNil(env["MY_UNREQUESTED_SECRET"])
    }

    /// `source: "remote"` env_vars are an upstream remote-executor concept.
    /// On a LOCAL stdio launch upstream `local_stdio_env_var_names`
    /// (`rmcp-client/src/utils.rs:50-58`) treats this as a hard configuration
    /// error and refuses to start the server, rather than silently dropping
    /// the entry. We mirror that: `buildStdioEnvironment` throws
    /// `McpError.spawn` with the upstream message.
    func testBuildStdioEnvironmentRemoteSourceEnvVarThrows() {
        setenv("REMOTE_ONLY_TOKEN", "remote-secret", 1)
        defer { unsetenv("REMOTE_ONLY_TOKEN") }
        var cfg = McpServerConfig(name: "x", command: "echo")
        cfg.envVars = [McpServerEnvVar(name: "REMOTE_ONLY_TOKEN",
                                       source: "remote")]
        XCTAssertThrowsError(try McpClient.buildStdioEnvironment(config: cfg)) { err in
            let msg = "\(err)"
            XCTAssertTrue(msg.contains("uses source `remote`"), msg)
            XCTAssertTrue(msg.contains("REMOTE_ONLY_TOKEN"), msg)
            XCTAssertTrue(msg.contains("requires remote MCP stdio"), msg)
        }
    }

    /// Literal `env = { K = "v" }` overrides must win over the
    /// allowlist (upstream `.envs(envs)` is chained after the allowlist).
    func testBuildStdioEnvironmentLiteralOverrideWins() {
        // Mutating the process-wide PATH leaks across tests. Restore
        // afterwards — without this, later tests inherit a PATH of
        // just `/usr/bin` and `sleep` (which lives at `/bin/sleep` on
        // macOS) becomes unresolvable.
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        defer {
            if let p = originalPATH { setenv("PATH", p, 1) }
            else { unsetenv("PATH") }
        }
        setenv("PATH", "/usr/bin", 1)
        var cfg = McpServerConfig(name: "x", command: "echo")
        cfg.env = ["PATH": "/custom/path", "EXTRA": "ok"]
        let env = try! McpClient.buildStdioEnvironment(config: cfg)
        XCTAssertEqual(env["PATH"], "/custom/path")
        XCTAssertEqual(env["EXTRA"], "ok")
    }

    /// End-to-end: spawn a python MCP server that reports its own env via
    /// a tools/call response, assert (a) parent secrets are not present
    /// (b) explicit env_vars/env entries ARE present. This is the
    /// behavioral guard for the F6 fix.
    func testMcpStdioEnvIsClearedByDefault() async throws {
        let dir = NSTemporaryDirectory() + "mcpsrv-env-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
        // Mock server: serialise the entire `os.environ` dict as JSON in
        // the tools/call response, so the test can inspect it.
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
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"tools":[{"name":"env","description":"","inputSchema":{"type":"object"}}]}}), flush=True)
            elif m == "tools/call":
                envdump = json.dumps(dict(os.environ))
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":envdump}],"isError":False}}), flush=True)
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)

        // Plant a secret in the parent env that MUST NOT reach the child.
        setenv("CODEX_API_KEY", "leaked-secret-MUST-NOT-APPEAR", 1)
        defer { unsetenv("CODEX_API_KEY") }
        // Plant a custom var that we opt into via env_vars.
        setenv("MCP_TEST_OPT_IN", "opted-in", 1)
        defer { unsetenv("MCP_TEST_OPT_IN") }

        var cfg = McpServerConfig(name: "envcheck", command: "python3",
                                   args: [script])
        cfg.envVars = [McpServerEnvVar(name: "MCP_TEST_OPT_IN")]
        cfg.env = ["MCP_LITERAL": "literal-value"]
        let client = McpClient(cfg, requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()
        let r = try await client.callTool("env", argumentsJSON: "{}")
        await client.stop()

        guard let data = r.text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return XCTFail("mock server did not return parseable env dump: \(r.text)")
        }

        XCTAssertNil(obj["CODEX_API_KEY"],
                     "F6 LEAK: CODEX_API_KEY reached MCP child process. env dump: \(obj.keys.sorted())")
        XCTAssertEqual(obj["MCP_TEST_OPT_IN"], "opted-in",
                       "env_vars opt-in must forward the var")
        XCTAssertEqual(obj["MCP_LITERAL"], "literal-value",
                       "literal env override must forward")
        XCTAssertNotNil(obj["PATH"],
                        "PATH must remain so the child can resolve binaries")
    }

    // MARK: - F7: process group isolation + graceful shutdown

    /// The child process's PGID must equal its PID — i.e. it's a process
    /// group leader rather than sharing the parent's group. We assert
    /// this via `getpgid()` on the child PID while it's alive.
    func testMcpStdioRunsInOwnProcessGroup() async throws {
        // A long-running python server that we can keep alive long enough
        // to inspect its pgid.
        let dir = NSTemporaryDirectory() + "mcpsrv-pg-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
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
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        let cfg = McpServerConfig(name: "pgcheck", command: "python3",
                                   args: [script])
        let client = McpClient(cfg, requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()

        // Pull the child PID. McpClient exposes it via a small reflection
        // helper for tests. (We add `_testChildPID()` to the client.)
        guard let pid = await client._testChildPID() else {
            await client.stop()
            return XCTFail("could not obtain child PID")
        }
        XCTAssertGreaterThan(pid, 0)
        // The parent's PGID is whatever the test runner is in. The child
        // must be in its OWN group — i.e. pgid == pid.
        let childPgid = getpgid(pid)
        let parentPgid = getpgid(getpid())
        XCTAssertEqual(childPgid, pid,
                       "F7: stdio child must be its own process group leader (pgid=\(childPgid) pid=\(pid))")
        XCTAssertNotEqual(childPgid, parentPgid,
                          "F7: child group must differ from parent group")
        await client.stop()
    }

    /// Stop must SIGTERM first, give up to 2 seconds of grace, then
    /// SIGKILL. We verify the grace behavior by spawning a child that
    /// IGNORES SIGTERM (`signal.signal(signal.SIGTERM, signal.SIG_IGN)`)
    /// so we can measure how long the parent waits before escalating
    /// to SIGKILL. A correct impl waits ~2s; the bug (immediate SIGKILL)
    /// would wait ~0ms. This is robust against the XCTest sandbox
    /// blocking child-process file writes — no sentinel needed.
    func testMcpStdioGracefulShutdownGivesTimeBeforeKill() async throws {
        let dir = "/tmp/mcpsrv-term-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
        // Server installs a SIGTERM handler that writes the sentinel,
        // then exits. If we SIGKILL'd straight away the handler would
        // never run.
        // We can't rely on Python signal-handler-during-blocking-readline
        // (EINTR retries default to True on Py3). Instead use select()
        // with a short timeout so the main loop yields to bytecode often,
        // letting Python dispatch our SIGTERM handler reliably.
        let body = """
        import sys, json, signal, os, time
        # IGNORE SIGTERM so the parent must escalate to SIGKILL after
        # the 2s grace period. This lets the test measure elapsed time
        # without depending on the child writing files (which the
        # XCTest sandbox blocks).
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            line = sys.stdin.readline()
            if not line:
                time.sleep(0.05)
                continue
            s = line.strip()
            if not s:
                continue
            try:
                msg = json.loads(s)
            except Exception:
                continue
            m = msg.get('method'); i = msg.get('id')
            if m == 'initialize':
                print(json.dumps({'jsonrpc':'2.0','id':i,'result':{'protocolVersion':'2025-06-18'}}), flush=True)
            elif m == 'notifications/initialized':
                pass
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        let cfg = McpServerConfig(name: "termcheck", command: "python3",
                                   args: [script])
        let client = McpClient(cfg, requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()
        let t0 = Date()
        await client.stop()
        let elapsed = Date().timeIntervalSince(t0)
        // A correct impl: SIGTERM ignored, polls for ~2s, then SIGKILLs.
        // The bug (immediate SIGKILL with no grace): elapsed near zero.
        // Allow a small upper margin (3.5s) for slow CI.
        XCTAssertGreaterThan(elapsed, 1.5,
            "F7: stop() returned in \(elapsed)s — no grace period was given before SIGKILL")
        XCTAssertLessThan(elapsed, 3.5,
            "F7: stop() took \(elapsed)s — should be ~2s grace then SIGKILL, not unbounded")
    }

    // MARK: - F8: OAuth store wiring

    /// Verifies both daemon entrypoints (`codex-session/main.swift` and
    /// `codexd/CodexDaemon.swift`) pass a real `McpOAuthStore` into
    /// `McpManager.startAll`, not `nil`. We do this via a source-text grep
    /// — the failure mode is a single-line regression that's hard to
    /// notice in code review, and grep is the cheapest detector.
    func testMcpOAuthStoreLoadedInDaemon() throws {
        // Locate the repo root by walking up from the test bundle until
        // we find the `Sources/codex-session` directory.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var root: URL?
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir
                                 .appendingPathComponent("Sources/codex-session")
                                 .path) {
                root = dir
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        guard let root else {
            // Skip rather than fail if we can't locate sources (e.g. an
            // unusual test layout).
            return
        }
        let paths = [
            root.appendingPathComponent("Sources/codex-session/main.swift").path,
            root.appendingPathComponent("Sources/codexd/CodexDaemon.swift").path,
        ]
        for p in paths {
            guard let data = fm.contents(atPath: p),
                  let text = String(data: data, encoding: .utf8) else {
                return XCTFail("could not read \(p)")
            }
            // Each main.swift must instantiate the store and pass it.
            XCTAssertTrue(text.contains("McpOAuthStore(codexHome: codexHome)"),
                          "F8: \(p) must instantiate McpOAuthStore(codexHome:)")
            XCTAssertFalse(text.contains("oauthStore: nil"),
                           "F8: \(p) must NOT pass oauthStore: nil to startAll")
        }
    }
}

/// JSON-string-escape helper for safely embedding paths in inline python.
private func jsonEscape(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
    // ["…"]  → strip brackets.
    let raw = String(data: data, encoding: .utf8) ?? "\"\""
    return String(raw.dropFirst().dropLast())
}
