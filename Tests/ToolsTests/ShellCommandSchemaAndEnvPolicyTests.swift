import XCTest
import Foundation
@testable import Tools
@testable import Sandbox

/// Parity tests for the `exec-unified-shell` audit unit:
/// - `shell_command` tool description / property descriptions / schema flags
///   match upstream `core/src/tools/handlers/shell_spec.rs::create_shell_command_tool`.
/// - `ShellEnvironmentPolicyConfig.populateEnv` reproduces upstream
///   `protocol/src/shell_environment.rs::populate_env`.
/// - The restrictive `SandboxEnvironmentPolicy.default` injects `CODEX_THREAD_ID`.
final class ShellCommandSchemaAndEnvPolicyTests: XCTestCase {

    private func shellTool() -> ShellTool {
        ShellTool(sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
    }

    // MARK: shell_command schema / description parity

    func testShellCommandDescriptionIsUpstreamVerbatim() {
        XCTAssertEqual(
            shellTool().toolDescription,
            "Runs a shell command and returns its output.\n"
            + "- Always set the `workdir` param when using the shell_command "
            + "function. Do not use `cd` unless absolutely necessary.")
    }

    func testShellCommandSchemaMatchesUpstream() throws {
        let tool = shellTool()
        let obj = try JSONSerialization.jsonObject(
            with: Data(tool.jsonSchema.utf8)) as? [String: Any]
        guard let obj else { return XCTFail("schema must be a JSON object") }
        let props = obj["properties"] as? [String: Any] ?? [:]
        // Upstream `create_shell_command_tool` advertises command/workdir/timeout_ms
        // PLUS the unconditionally-inserted approval triplet (sandbox_permissions,
        // justification, prefix_rule). `login` is NOT here (allow_login_shell off).
        XCTAssertEqual(Set(props.keys),
                       ["command", "workdir", "timeout_ms",
                        "sandbox_permissions", "justification", "prefix_rule"],
                       "shell_command must advertise command/workdir/timeout_ms + approval triplet")
        XCTAssertNil(props["login"],
                     "login must NOT be advertised when allow_login_shell is off")
        // Approval triplet types: sandbox_permissions/justification are strings,
        // prefix_rule is an array<string>.
        XCTAssertEqual((props["sandbox_permissions"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["justification"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["prefix_rule"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual(((props["prefix_rule"] as? [String: Any])?["items"] as? [String: Any])?["type"] as? String,
                       "string", "prefix_rule items are strings")
        // Verbatim upstream `shell_spec.rs:287-313` descriptions.
        XCTAssertEqual((props["sandbox_permissions"] as? [String: Any])?["description"] as? String,
                       "Sandbox permissions for the command. Set to \"require_escalated\" to request running without sandbox restrictions; defaults to \"use_default\".")
        XCTAssertEqual((props["command"] as? [String: Any])?["description"] as? String,
                       "The shell script to execute in the user's default shell")
        // Upstream `shell_spec.rs:148-154` builds `command` via
        // `JsonSchema::string(...)`, so it carries `"type":"string"`.
        XCTAssertEqual((props["command"] as? [String: Any])?["type"] as? String, "string",
                       "upstream types command as `string`")
        XCTAssertEqual((props["workdir"] as? [String: Any])?["description"] as? String,
                       "The working directory to execute the command in")
        XCTAssertEqual((props["timeout_ms"] as? [String: Any])?["description"] as? String,
                       "The timeout for the command in milliseconds")
        XCTAssertEqual((props["timeout_ms"] as? [String: Any])?["type"] as? String, "number",
                       "upstream types timeout_ms as `number`")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                       "upstream sets additionalProperties:false")
        XCTAssertEqual(obj["required"] as? [String], ["command"],
                       "required must be exactly [command]")
        // The non-upstream `terminate`/`cwd`/`timeout` aliases must not be advertised.
        XCTAssertNil(props["cwd"])
    }

    func testShellCommandSchemaAdvertisesLoginWhenAllowLoginShell() throws {
        let tool = ShellTool(sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)),
                             allowLoginShell: true)
        let obj = try JSONSerialization.jsonObject(
            with: Data(tool.jsonSchema.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["login"],
                        "login must be advertised when allow_login_shell is on")
        XCTAssertEqual((props["login"] as? [String: Any])?["type"] as? String, "boolean")
        XCTAssertEqual((props["login"] as? [String: Any])?["description"] as? String,
                       "Whether to run the shell with login shell semantics. Defaults to true.")
        // The approval triplet remains present alongside login.
        XCTAssertEqual(Set(props.keys),
                       ["command", "workdir", "timeout_ms", "login",
                        "sandbox_permissions", "justification", "prefix_rule"])
    }

    /// Even when the model emits `login:true` against a tool with
    /// allow_login_shell OFF, the request is rejected (upstream parity); the
    /// escalation triplet keys are accepted (not treated as decode errors).
    func testShellCommandRejectsLoginWhenDisabled() async throws {
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true,
                             allowLoginShell: false)
        let call = ToolCall(callId: "c1", name: "shell_command",
            argumentsJSON: #"{"command":"echo hi","login":true,"sandbox_permissions":"require_escalated","justification":"x","prefix_rule":["echo"]}"#)
        let r = try await tool.run(call, cwd: NSTemporaryDirectory())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("login shell is disabled"),
                      "explicit login:true with allow_login_shell off must be rejected")
    }

    /// The escalation triplet + login:false decode cleanly (no decode failure)
    /// so the command still runs.
    func testShellCommandAcceptsApprovalTripletKeys() async throws {
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let call = ToolCall(callId: "c2", name: "shell_command",
            argumentsJSON: #"{"command":"/bin/echo ok","sandbox_permissions":"require_escalated","justification":"do the thing","prefix_rule":["git","pull"],"login":false}"#)
        let r = try await tool.run(call, cwd: NSTemporaryDirectory())
        // fullAccess + AlwaysDenySandbox: /bin/echo runs (sandbox not consulted).
        XCTAssertTrue(r.output.contains("ok"),
                      "valid args with the approval triplet must not fail decoding")
    }

    // MARK: EnvPattern (WildMatchPattern<'*','?'>) parity

    func testEnvPatternCaseInsensitiveSubstring() {
        // `*KEY*` is a case-insensitive substring match (upstream default exclude).
        XCTAssertTrue(EnvPattern.matches(pattern: "*KEY*", name: "OPENAI_API_KEY"))
        XCTAssertTrue(EnvPattern.matches(pattern: "*KEY*", name: "my_key_here"))
        XCTAssertTrue(EnvPattern.matches(pattern: "*KEY*", name: "KEYCHAIN"))
        XCTAssertTrue(EnvPattern.matches(pattern: "*SECRET*", name: "app_secret_val"))
        XCTAssertTrue(EnvPattern.matches(pattern: "*TOKEN*", name: "GH_TOKEN"))
        XCTAssertFalse(EnvPattern.matches(pattern: "*KEY*", name: "PATH"))
        // `?` matches exactly one char; anchored exact otherwise.
        XCTAssertTrue(EnvPattern.matches(pattern: "FO?", name: "FOO"))
        XCTAssertFalse(EnvPattern.matches(pattern: "FO?", name: "FOOO"))
        XCTAssertTrue(EnvPattern.matches(pattern: "FOO", name: "foo"))
        XCTAssertFalse(EnvPattern.matches(pattern: "FOO", name: "FOOBAR"))
    }

    // MARK: populate_env algorithm parity

    func testPopulateEnvInheritAllNoScrubByDefault() {
        // Upstream default: inherit All, ignore_default_excludes true => verbatim.
        let vars = ["PATH": "/usr/bin", "OPENAI_API_KEY": "sk-x", "FOO": "bar"]
        let out = ShellEnvironmentPolicyConfig.default.populateEnv(vars, threadId: nil)
        XCTAssertEqual(out["OPENAI_API_KEY"], "sk-x",
                       "default ignore_default_excludes=true leaks secrets verbatim (upstream parity)")
        XCTAssertEqual(out["PATH"], "/usr/bin")
        XCTAssertEqual(out["FOO"], "bar")
    }

    func testPopulateEnvDefaultExcludesWhenNotIgnored() {
        let policy = ShellEnvironmentPolicyConfig(
            inherit: .all, ignoreDefaultExcludes: false,
            exclude: [], set: [:], includeOnly: [])
        let vars = ["PATH": "/usr/bin", "OPENAI_API_KEY": "sk-x",
                    "MY_SECRET": "s", "AUTH_TOKEN": "t", "PLAIN": "v"]
        let out = policy.populateEnv(vars, threadId: nil)
        XCTAssertNil(out["OPENAI_API_KEY"], "*KEY* excluded")
        XCTAssertNil(out["MY_SECRET"], "*SECRET* excluded")
        XCTAssertNil(out["AUTH_TOKEN"], "*TOKEN* excluded")
        XCTAssertEqual(out["PATH"], "/usr/bin")
        XCTAssertEqual(out["PLAIN"], "v")
    }

    func testPopulateEnvCoreInheritFiltersToCoreVars() {
        let policy = ShellEnvironmentPolicyConfig(
            inherit: .core, ignoreDefaultExcludes: true,
            exclude: [], set: [:], includeOnly: [])
        let vars = ["PATH": "/usr/bin", "HOME": "/h", "FOO": "bar", "SHELL": "/bin/sh"]
        let out = policy.populateEnv(vars, threadId: nil)
        XCTAssertEqual(Set(out.keys), ["PATH", "HOME", "SHELL"],
                       "Core inherit keeps only UNIX_CORE_ENV_VARS")
    }

    func testPopulateEnvSetThenIncludeOnlyThenThreadId() {
        let policy = ShellEnvironmentPolicyConfig(
            inherit: .all, ignoreDefaultExcludes: true,
            exclude: ["FOO"], set: ["EXTRA": "z"], includeOnly: ["EXTRA", "PATH"])
        let vars = ["PATH": "/usr/bin", "FOO": "bar", "BAR": "baz"]
        let out = policy.populateEnv(vars, threadId: "thread-123")
        // FOO excluded; include_only keeps EXTRA + PATH; thread id always injected.
        XCTAssertNil(out["FOO"])
        XCTAssertNil(out["BAR"], "include_only drops non-matching vars")
        XCTAssertEqual(out["EXTRA"], "z")
        XCTAssertEqual(out["PATH"], "/usr/bin")
        XCTAssertEqual(out["CODEX_THREAD_ID"], "thread-123",
                       "thread id injected last regardless of include_only")
    }

    // MARK: CODEX_THREAD_ID injection under the restrictive default

    func testRestrictiveDefaultInjectsCodexThreadId() {
        // The restrictive allowlist would normally strip an unknown var, but
        // CODEX_THREAD_ID is read-only run metadata and is injected post-scrub.
        let parent = ["PATH": "/usr/bin", "CODEX_THREAD_ID": "tid-abc",
                      "OPENAI_API_KEY": "sk-secret"]
        let out = SandboxEnvironmentPolicy.default.scrub(parent)
        XCTAssertEqual(out["CODEX_THREAD_ID"], "tid-abc",
                       "CODEX_THREAD_ID must propagate to the child (upstream parity)")
        XCTAssertNil(out["OPENAI_API_KEY"],
                     "restrictive default still strips secrets")
        XCTAssertEqual(out["PATH"], "/usr/bin")
    }

    func testRestrictiveDefaultOmitsThreadIdWhenParentLacksIt() {
        let out = SandboxEnvironmentPolicy.default.scrub(["PATH": "/usr/bin"])
        XCTAssertNil(out["CODEX_THREAD_ID"],
                     "no CODEX_THREAD_ID injected when the parent does not set it")
    }

    // MARK: CODEX_SANDBOX / CODEX_SANDBOX_NETWORK_DISABLED post-scrub injection
    // (upstream core/src/spawn.rs:78-80 + core/src/sandboxing/mod.rs:133-142)

    func testScrubInjectsNetworkDisabledWhenSet() {
        var policy = SandboxEnvironmentPolicy.default
        policy.networkDisabled = true
        let out = policy.scrub(["PATH": "/usr/bin"])
        XCTAssertEqual(out["CODEX_SANDBOX_NETWORK_DISABLED"], "1",
                       "network-disabled var must be injected post-scrub")
    }

    func testScrubOmitsNetworkDisabledByDefault() {
        let out = SandboxEnvironmentPolicy.default.scrub(["PATH": "/usr/bin"])
        XCTAssertNil(out["CODEX_SANDBOX_NETWORK_DISABLED"],
                     "no network-disabled var when network is enabled")
    }

    func testScrubInjectsSandboxTypeWhenSet() {
        var policy = SandboxEnvironmentPolicy.default
        policy.injectedSandboxType = "seatbelt"
        let out = policy.scrub(["PATH": "/usr/bin"])
        XCTAssertEqual(out["CODEX_SANDBOX"], "seatbelt",
                       "CODEX_SANDBOX must be injected post-scrub when set")
    }

    func testScrubOmitsSandboxTypeByDefault() {
        let out = SandboxEnvironmentPolicy.default.scrub(["PATH": "/usr/bin"])
        XCTAssertNil(out["CODEX_SANDBOX"], "no CODEX_SANDBOX when type is nil")
    }

    func testWorkspaceSandboxRestrictedModeSetsNetworkDisabled() {
        // A read-only / workspace-write policy with networkAllowed == false must
        // surface CODEX_SANDBOX_NETWORK_DISABLED=1 in the spawn env policy.
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                networkAllowed: false))
        XCTAssertTrue(sb.spawnEnvironmentPolicy.networkDisabled)
        let env = sb.spawnEnvironmentPolicy.scrub(["PATH": "/usr/bin"])
        XCTAssertEqual(env["CODEX_SANDBOX_NETWORK_DISABLED"], "1")
    }

    func testWorkspaceSandboxNetworkEnabledOmitsNetworkDisabled() {
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                networkAllowed: true))
        XCTAssertFalse(sb.spawnEnvironmentPolicy.networkDisabled)
        let env = sb.spawnEnvironmentPolicy.scrub(["PATH": "/usr/bin"])
        XCTAssertNil(env["CODEX_SANDBOX_NETWORK_DISABLED"])
    }

    #if os(macOS)
    func testWorkspaceSandboxMacosSeatbeltTagWhenBackendAvailable() throws {
        // On macOS, a non-full-access policy with sandbox-exec available must
        // inject CODEX_SANDBOX=seatbelt. A danger-full-access policy must not.
        let resolverAvailable = SandboxBackendResolver()
        let backendAvailable: Bool
        if case .sandboxExec = resolverAvailable.resolve() { backendAvailable = true }
        else { backendAvailable = false }
        guard backendAvailable else {
            throw XCTSkip("sandbox-exec backend unavailable on this host")
        }
        let confined = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite))
        XCTAssertEqual(confined.spawnEnvironmentPolicy.injectedSandboxType, "seatbelt")
        let fullAccess = WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess))
        XCTAssertNil(fullAccess.spawnEnvironmentPolicy.injectedSandboxType,
                     "danger-full-access bypasses confinement → no CODEX_SANDBOX")
    }
    #endif
}
