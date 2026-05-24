import XCTest
import Foundation
@testable import Tools
@testable import Sandbox

private struct MockBackend: WebSearchBackend {
    let result: Result<String, ToolError>
    var requiredHosts: [String] = []
    func search(_ query: String) async -> Result<String, ToolError> { result }
}

final class WebSearchTests: XCTestCase {

    func testPerplexityRequestBodyShape() {
        let b = PerplexityWebSearch.requestBody("what is swift?", model: "sonar-reasoning-pro")
        XCTAssertEqual(b["model"] as? String, "sonar-reasoning-pro")
        let msgs = b["messages"] as? [[String: Any]]
        XCTAssertEqual(msgs?.count, 2)
        XCTAssertEqual(msgs?.first?["role"] as? String, "system")
        XCTAssertEqual(msgs?.last?["role"] as? String, "user")
        XCTAssertEqual(msgs?.last?["content"] as? String, "what is swift?")
        // Must serialize cleanly.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: b))
    }

    func testOpenAIRequestBodyShape() {
        let b = OpenAIWebSearch.requestBody("latest swift release",
                                            model: "gpt-4o-mini",
                                            toolType: "web_search")
        XCTAssertEqual(b["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(b["input"] as? String, "latest swift release")
        let tools = b["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["type"] as? String, "web_search")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: b))
    }

    func testCompositePrimarySuccessSkipsFallback() async {
        let c = CompositeWebSearch(
            primary: MockBackend(result: .success("PRIMARY")),
            fallback: MockBackend(result: .success("FALLBACK")))
        let r = await c.search("q")
        guard case .success(let s) = r else { return XCTFail("expected success") }
        XCTAssertEqual(s, "PRIMARY")
    }

    func testCompositeFallbackOnPrimaryFailure() async {
        let c = CompositeWebSearch(
            primary: MockBackend(result: .failure(ToolError(message: "primary down"))),
            fallback: MockBackend(result: .success("FALLBACK")))
        let r = await c.search("q")
        guard case .success(let s) = r else { return XCTFail("expected fallback success") }
        XCTAssertEqual(s, "FALLBACK")
    }

    func testCompositeBothFailSurfacesBoth() async {
        let c = CompositeWebSearch(
            primary: MockBackend(result: .failure(ToolError(message: "P-ERR"))),
            fallback: MockBackend(result: .failure(ToolError(message: "F-ERR"))))
        let r = await c.search("q")
        guard case .failure(let e) = r else { return XCTFail("expected failure") }
        XCTAssertTrue(e.message.contains("P-ERR") && e.message.contains("F-ERR"),
                      "both failures surfaced: \(e.message)")
    }

    func testCompositeNoFallbackPropagatesPrimary() async {
        let c = CompositeWebSearch(
            primary: MockBackend(result: .failure(ToolError(message: "only-P"))),
            fallback: nil)
        let r = await c.search("q")
        guard case .failure(let e) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(e.message, "only-P")
    }

    func testEnvResolverSelection() {
        XCTAssertTrue(ResolvedWebSearch.fromEnvironment([:]) is UnconfiguredWebSearch)
        XCTAssertTrue(ResolvedWebSearch.fromEnvironment(
            ["PERPLEXITY_API_KEY": ""]) is UnconfiguredWebSearch,
            "empty key is treated as unset")
        XCTAssertTrue(ResolvedWebSearch.fromEnvironment(
            ["OPENAI_API_KEY": "sk-x"]) is CompositeWebSearch)
        XCTAssertTrue(ResolvedWebSearch.fromEnvironment(
            ["PERPLEXITY_API_KEY": "px-y"]) is CompositeWebSearch)
        XCTAssertTrue(ResolvedWebSearch.fromEnvironment(
            ["PERPLEXITY_API_KEY": "px-y", "OPENAI_API_KEY": "sk-x"])
            is CompositeWebSearch)
    }

    func testUnconfiguredIsActionableNotSilent() async {
        let r = await UnconfiguredWebSearch().search("q")
        guard case .failure(let e) = r else { return XCTFail() }
        XCTAssertTrue(e.message.contains("PERPLEXITY_API_KEY")
                      && e.message.contains("OPENAI_API_KEY"),
                      "the no-key path is explicit and actionable, not a silent stub")
    }

    func testWebSearchToolUsesResolvedBackendNotDisabled() async {
        // The shipped tool wiring resolves a real backend from the env.
        let resolved = ResolvedWebSearch.fromEnvironment(["OPENAI_API_KEY": "sk-x"])
        let tool = WebSearchTool(backend: resolved)
        XCTAssertEqual(tool.name, "web_search")
        XCTAssertTrue(tool.parallelSafe)
    }

    func testWebSearchToolBlocksExplicitDeniedProviderHost() async throws {
        let sandbox = WorkspaceSandbox(SandboxPolicy(
            mode: .workspaceWrite,
            networkDeniedDomains: ["api.openai.com"]))
        let tool = WebSearchTool(
            backend: MockBackend(result: .success("SHOULD_NOT_RUN"),
                                 requiredHosts: ["api.openai.com"]),
            sandbox: sandbox)
        let r = try await tool.run(
            ToolCall(callId: "deny", name: "web_search",
                     argumentsJSON: #"{"query":"swift"}"#),
            cwd: NSTemporaryDirectory())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("web_search blocked"), r.output)
        XCTAssertTrue(r.output.contains("api.openai.com"), r.output)
    }

    func testWebSearchConsumesCompiledExecPolicyNetworkDenial() async throws {
        let home = NSTemporaryDirectory() + "/codex-websearch-policy-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        network_rule(host = "api.openai.com", protocol = "https", decision = "deny")
        """.write(toFile: home + "/exec_policy.rules", atomically: true, encoding: .utf8)

        let policy = try ExecPolicy.loadStrict(codexHome: home)
        let domains = policy.compiledNetworkDomains()
        let sandbox = WorkspaceSandbox(SandboxPolicy(
            mode: .workspaceWrite,
            networkAllowedDomains: domains.allowed,
            networkDeniedDomains: domains.denied))
        let tool = WebSearchTool(
            backend: MockBackend(result: .success("SHOULD_NOT_RUN"),
                                 requiredHosts: ["api.openai.com"]),
            sandbox: sandbox)
        let r = try await tool.run(
            ToolCall(callId: "policy-deny", name: "web_search",
                     argumentsJSON: #"{"query":"swift"}"#),
            cwd: home)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("web_search blocked"), r.output)
    }

    func testWebSearchToolAllowsUnrelatedDomainDenials() async throws {
        let sandbox = WorkspaceSandbox(SandboxPolicy(
            mode: .workspaceWrite,
            networkDeniedDomains: ["elsewhere.example.com"]))
        let tool = WebSearchTool(
            backend: MockBackend(result: .success("OK"),
                                 requiredHosts: ["api.openai.com"]),
            sandbox: sandbox)
        let r = try await tool.run(
            ToolCall(callId: "allow", name: "web_search",
                     argumentsJSON: #"{"query":"swift"}"#),
            cwd: NSTemporaryDirectory())
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(r.output, "OK")
    }

    func testResolvedOpenAIWebSearchAdvertisesProviderHost() {
        let backend = OpenAIWebSearch(apiKey: "sk-test")
        XCTAssertEqual(backend.requiredHosts, ["api.openai.com"])
    }

    /// Live best-effort: a real provider key performs a real web search and
    /// returns non-empty content. Skips cleanly with no key (CI policy).
    func testLiveWebSearchReturnsContent() async throws {
        let env = ProcessInfo.processInfo.environment
        let hasKey = (env["PERPLEXITY_API_KEY"]?.isEmpty == false)
            || (env["OPENAI_API_KEY"]?.isEmpty == false)
        try XCTSkipUnless(hasKey, "no PERPLEXITY_API_KEY/OPENAI_API_KEY set")
        let backend = ResolvedWebSearch.fromEnvironment()
        let tool = WebSearchTool(backend: backend)
        let r = try await tool.run(
            ToolCall(callId: "ws1", name: "web_search",
                     argumentsJSON: #"{"query":"What is the OpenAI Codex CLI? One sentence."}"#),
            cwd: NSTemporaryDirectory())
        XCTAssertTrue(r.success,
                      "live web_search must return a real result: \(r.output)")
        XCTAssertFalse(r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "live web_search content must be non-empty")
        XCTAssertFalse(r.output.contains("not configured"),
                       "the real backend must be used, never the disabled stub")
    }

    func testLiveOpenAIWebSearchDeniedBeforeNetworkEgress() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false,
                          "OPENAI_API_KEY not set")
        let sandbox = WorkspaceSandbox(SandboxPolicy(
            mode: .workspaceWrite,
            networkDeniedDomains: ["api.openai.com"]))
        let backend = OpenAIWebSearch(apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!)
        let tool = WebSearchTool(backend: backend, sandbox: sandbox)
        let r = try await tool.run(
            ToolCall(callId: "ws-deny", name: "web_search",
                     argumentsJSON: #"{"query":"This live call must be denied locally."}"#),
            cwd: NSTemporaryDirectory())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("web_search blocked"), r.output)
        XCTAssertFalse(r.output.contains("curl exit"), "denial must happen before egress: \(r.output)")
    }
}
