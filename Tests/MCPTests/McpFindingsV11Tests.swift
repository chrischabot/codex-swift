import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import ProtocolModel

/// Targeted unit tests for the v11 MCP audit findings:
///   1. `codex/sandbox-state-meta` capability is parsed from the `initialize`
///      result and the `SandboxState` payload is injected into `tools/call`
///      `_meta` for capable servers (and ONLY those).
///   2. Server `instructions` from `initialize` are captured and surfaced as
///      the namespace description on each registered proxy.
final class McpFindingsV11Tests: XCTestCase {

    /// Records the full `meta` map handed to `callTool` so we can assert the
    /// proxy injected (or omitted) the sandbox-state-meta object verbatim.
    private actor RecordingMcpClient: McpClientProtocol {
        private var lastMeta: [String: Any]?
        let supportsSandbox: Bool
        let instructionsValue: String?
        init(supportsSandbox: Bool = false, instructions: String? = nil) {
            self.supportsSandbox = supportsSandbox
            self.instructionsValue = instructions
        }
        func start() throws {}
        func initialize() async throws {}
        func supportsSandboxStateMeta() async -> Bool { supportsSandbox }
        func serverInstructions() async -> String? { instructionsValue }
        func listTools() async throws -> [McpToolSpec] { [] }
        func callTool(_ name: String, argumentsJSON: String,
                      meta: [String: Any]?,
                      elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult {
            lastMeta = meta
            return McpCallResult(text: "ok", isError: false)
        }
        func readResource(uri: String) async throws -> [String: JSONLite] { [:] }
        func stop() async {}

        // Sendable extracts (the raw `[String: Any]` dict cannot cross the
        // actor boundary). All assertions read these.
        func threadIdMeta() -> String? { lastMeta?["threadId"] as? String }
        func hasSandboxMeta() -> Bool {
            lastMeta?[SandboxStateMeta.metaKey] is [String: Any]
        }
        /// JSON-encode the recorded `_meta` (it is JSONSerialization-shaped on
        /// the wire) so the test can decode it back into Sendable JSONLite.
        func metaAsJSONLite() -> JSONLite? {
            guard let m = lastMeta,
                  JSONSerialization.isValidJSONObject(m),
                  let d = try? JSONSerialization.data(withJSONObject: m),
                  let v = try? JSONLite.parse(d) else { return nil }
            return v
        }
    }

    private func sampleState(mode: SandboxModeKind = .workspaceWrite,
                             roots: [String] = ["/work"],
                             net: Bool = false) -> SandboxStateMeta {
        SandboxStateMeta(
            sandboxPolicy: SandboxStateMeta.policy(mode: mode, writableRoots: roots,
                                                   networkAccess: net),
            sandboxCwd: "/work",
            useLegacyLandlock: false)
    }

    // MARK: - Finding 1: sandbox-state-meta injection (capability-gated)

    func testInjectsSandboxStateForCapableServer() async throws {
        let client = RecordingMcpClient(supportsSandbox: true)
        let proxy = McpToolProxy(
            server: "srv", tool: "do_thing", client: client,
            threadId: "conv-1",
            sandboxState: sampleState(),
            serverSupportsSandboxStateMeta: true)
        _ = try await proxy.run(ToolCall(callId: "c1", name: proxy.name,
                                         argumentsJSON: "{}"), cwd: "/")
        guard case .object(let meta)? = await client.metaAsJSONLite() else {
            return XCTFail("expected an object _meta")
        }
        XCTAssertEqual(meta["threadId"], .string("conv-1"))
        guard case .object(let ss)? = meta[SandboxStateMeta.metaKey] else {
            return XCTFail("capable server must receive codex/sandbox-state-meta")
        }
        XCTAssertEqual(ss["sandboxCwd"], .string("/work"))
        XCTAssertEqual(ss["useLegacyLandlock"], .bool(false))
        // permissionProfile omitted (nil → key absent, per skip_serializing_if).
        XCTAssertNil(ss["permissionProfile"])
        // codexLinuxSandboxExe always present, null when nil.
        XCTAssertEqual(ss["codexLinuxSandboxExe"], .null)
        guard case .object(let policy)? = ss["sandboxPolicy"] else {
            return XCTFail("missing sandboxPolicy")
        }
        XCTAssertEqual(policy["type"], .string("workspace-write"))
        XCTAssertEqual(policy["writable_roots"], .array([.string("/work")]))
        XCTAssertEqual(policy["network_access"], .bool(false))
    }

    func testOmitsSandboxStateForUncapableServer() async throws {
        let client = RecordingMcpClient(supportsSandbox: false)
        // Even with a sandboxState supplied, an uncapable server must NOT
        // receive the key — only threadId.
        let proxy = McpToolProxy(
            server: "srv", tool: "do_thing", client: client,
            threadId: "conv-1",
            sandboxState: sampleState(),
            serverSupportsSandboxStateMeta: false)
        _ = try await proxy.run(ToolCall(callId: "c1", name: proxy.name,
                                         argumentsJSON: "{}"), cwd: "/")
        let tid = await client.threadIdMeta()
        let hasSandbox = await client.hasSandboxMeta()
        XCTAssertEqual(tid, "conv-1")
        XCTAssertFalse(hasSandbox,
                       "uncapable server must not receive sandbox-state-meta")
    }

    func testSandboxStateInjectedEvenWithoutThreadId() async throws {
        let client = RecordingMcpClient(supportsSandbox: true)
        let proxy = McpToolProxy(
            server: "srv", tool: "do_thing", client: client,
            threadId: nil,
            sandboxState: sampleState(),
            serverSupportsSandboxStateMeta: true)
        _ = try await proxy.run(ToolCall(callId: "c1", name: proxy.name,
                                         argumentsJSON: "{}"), cwd: "/")
        let tid = await client.threadIdMeta()
        let hasSandbox = await client.hasSandboxMeta()
        XCTAssertNil(tid)
        XCTAssertTrue(hasSandbox)
    }

    // MARK: - SandboxState wire-shape parity

    func testReadOnlyPolicyOmitsNetworkWhenFalse() {
        let state = SandboxStateMeta(
            sandboxPolicy: .readOnly(networkAccess: false),
            sandboxCwd: "/x")
        let policy = state.metaObject()["sandboxPolicy"] as? [String: Any]
        XCTAssertEqual(policy?["type"] as? String, "read-only")
        // skip_serializing_if = Not::not → omit when false.
        XCTAssertNil(policy?["network_access"])
    }

    func testReadOnlyPolicyEmitsNetworkWhenTrue() {
        let state = SandboxStateMeta(
            sandboxPolicy: .readOnly(networkAccess: true),
            sandboxCwd: "/x")
        let policy = state.metaObject()["sandboxPolicy"] as? [String: Any]
        XCTAssertEqual(policy?["network_access"] as? Bool, true)
    }

    func testDangerFullAccessPolicyIsBareType() {
        let state = SandboxStateMeta(sandboxPolicy: .dangerFullAccess, sandboxCwd: "/x")
        let policy = state.metaObject()["sandboxPolicy"] as? [String: Any]
        XCTAssertEqual(policy?["type"] as? String, "danger-full-access")
        XCTAssertEqual(policy?.count, 1, "danger-full-access carries no extra fields")
    }

    func testWorkspaceWriteOmitsEmptyWritableRoots() {
        let state = SandboxStateMeta(
            sandboxPolicy: .workspaceWrite(writableRoots: [], networkAccess: true,
                                           excludeTmpdirEnvVar: false,
                                           excludeSlashTmp: false),
            sandboxCwd: "/x")
        let policy = state.metaObject()["sandboxPolicy"] as? [String: Any]
        XCTAssertNil(policy?["writable_roots"], "empty writable_roots is skipped")
        XCTAssertEqual(policy?["network_access"] as? Bool, true)
        XCTAssertEqual(policy?["exclude_tmpdir_env_var"] as? Bool, false)
        XCTAssertEqual(policy?["exclude_slash_tmp"] as? Bool, false)
    }

    func testExternalSandboxPolicySerializesNetworkAccessString() {
        let state = SandboxStateMeta(
            sandboxPolicy: .externalSandbox(networkAccess: .enabled),
            sandboxCwd: "/x")
        let policy = state.metaObject()["sandboxPolicy"] as? [String: Any]
        XCTAssertEqual(policy?["type"] as? String, "external-sandbox")
        XCTAssertEqual(policy?["network_access"] as? String, "enabled")
    }

    func testPermissionProfilePresentWhenSupplied() {
        let pp = JSONLite.object(["type": .string("disabled")])
        let state = SandboxStateMeta(permissionProfile: pp,
                                     sandboxPolicy: .dangerFullAccess,
                                     sandboxCwd: "/x")
        let obj = state.metaObject()
        let profile = obj["permissionProfile"] as? [String: Any]
        XCTAssertEqual(profile?["type"] as? String, "disabled")
    }

    func testCodexLinuxSandboxExeEmitsValueWhenSet() {
        let state = SandboxStateMeta(sandboxPolicy: .dangerFullAccess,
                                     codexLinuxSandboxExe: "/usr/bin/codex-sb",
                                     sandboxCwd: "/x")
        XCTAssertEqual(state.metaObject()["codexLinuxSandboxExe"] as? String,
                       "/usr/bin/codex-sb")
    }

    /// The whole `_meta` object must round-trip through JSONSerialization
    /// (it is built with `JSONSerialization.data` on the wire).
    func testMetaObjectIsJSONSerializable() throws {
        let state = sampleState(mode: .workspaceWrite, roots: ["/a", "/b"], net: true)
        let meta: [String: Any] = [
            "threadId": "conv-1",
            SandboxStateMeta.metaKey: state.metaObject(),
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(meta))
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        XCTAssertFalse(data.isEmpty)
    }

    // MARK: - initialize result parsing (capability + instructions)

    func testApplyInitializeResultReadsCapabilityAndInstructions() {
        let result: [String: JSONLite] = [
            "capabilities": .object([
                "experimental": .object([
                    SandboxStateMeta.metaKey: .object([:]),
                ]),
            ]),
            "instructions": .string("  use carefully  "),
        ]
        var supports = false
        var instructions: String?
        McpClient.applyInitializeResult(result,
                                        sandboxStateMetaSupported: &supports,
                                        instructions: &instructions)
        XCTAssertTrue(supports)
        XCTAssertEqual(instructions, "use carefully", "trimmed instructions")
    }

    func testApplyInitializeResultAbsentCapability() {
        let result: [String: JSONLite] = [
            "capabilities": .object(["experimental": .object([:])]),
        ]
        var supports = true   // start true to prove it is not flipped on
        var instructions: String? = "stale"
        McpClient.applyInitializeResult(result,
                                        sandboxStateMetaSupported: &supports,
                                        instructions: &instructions)
        // No experimental key → not set to true by this call. (We seeded true
        // only to confirm the parser does not clear it; the real call sites
        // start from false.)
        XCTAssertTrue(supports)
        // No instructions key → leaves existing nil-or-value untouched.
        XCTAssertEqual(instructions, "stale")
    }

    func testApplyInitializeResultEmptyInstructionsBecomesNil() {
        let result: [String: JSONLite] = ["instructions": .string("   ")]
        var supports = false
        var instructions: String? = "x"
        McpClient.applyInitializeResult(result,
                                        sandboxStateMetaSupported: &supports,
                                        instructions: &instructions)
        XCTAssertFalse(supports)
        XCTAssertNil(instructions, "whitespace-only instructions → nil")
    }

    // MARK: - Finding 2: instructions surfaced on the proxy

    func testProxyCarriesServerInstructions() {
        let client = RecordingMcpClient(supportsSandbox: false,
                                        instructions: "be terse")
        let proxy = McpToolProxy(server: "srv", tool: "t", client: client,
                                 serverInstructions: "be terse")
        XCTAssertEqual(proxy.serverInstructions, "be terse")
    }
}
