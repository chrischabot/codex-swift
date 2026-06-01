import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import Prompts

/// Live-LLM end-to-end coverage for the harness file-I/O and web-search tools.
///
/// Every case pairs a DETERMINISTIC, model-independent assertion (direct
/// `router.dispatch`, real on-disk side-effects, the honest disabled-backend
/// path) with — where applicable — a BOUNDED live model turn whose only hard
/// guarantee is that it TERMINATES. We never assert that the model "said" or
/// "chose" anything; we assert the observable side-effect that occurs ONLY if
/// the feature worked (a real file on disk, a tool result success flag, the
/// exact refusal string).
final class LiveHarnessFileIoWebTests: XCTestCase {

    // MARK: 1. file tools real disk round-trip (happy)

    /// write_file -> read_file -> file_search -> list_dir all touch the real
    /// filesystem rooted at `work`. The deterministic half proves the bytes
    /// land on disk and round-trip through every reader; the live half only
    /// has to terminate.
    func testFileToolsRoundTripOnDisk() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("fio-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("fio-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let store = try lxStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))
        let (engine, _, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store)

        // --- Deterministic: write_file lands real bytes on disk. ---
        let wrote = await router.dispatch(
            ToolCall(callId: "wf1", name: "write_file",
                     argumentsJSON: #"{"path":"wf.txt","content":"WF_SENTINEL_42"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(wrote.success, "write_file succeeds: \(wrote.output)")
        XCTAssertTrue(wrote.output.contains("wrote"),
                      "write_file output confirms the write: \(wrote.output)")
        let onDisk = try String(contentsOfFile: work + "/wf.txt", encoding: .utf8)
        XCTAssertEqual(onDisk, "WF_SENTINEL_42",
                       "the exact bytes are on disk (no trailing newline injected)")

        // --- Deterministic: read_file returns the same bytes. ---
        let read = await router.dispatch(
            ToolCall(callId: "rf1", name: "read_file",
                     argumentsJSON: #"{"path":"wf.txt"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(read.success, "read_file succeeds: \(read.output)")
        XCTAssertTrue(read.output.contains("WF_SENTINEL_42"),
                      "read_file surfaces the on-disk content: \(read.output)")

        // --- Deterministic: file_search finds the file by fuzzy name. ---
        let search = await router.dispatch(
            ToolCall(callId: "fs1", name: "file_search",
                     argumentsJSON: #"{"query":"wf"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(search.success, "file_search succeeds: \(search.output)")
        XCTAssertTrue(search.output.contains("wf.txt"),
                      "file_search ranks the seeded file: \(search.output)")

        // --- Deterministic: list_dir enumerates the workspace. ---
        let list = await router.dispatch(
            ToolCall(callId: "ld1", name: "list_dir",
                     argumentsJSON: #"{}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(list.success, "list_dir succeeds: \(list.output)")
        XCTAssertTrue(list.output.contains("wf.txt"),
                      "list_dir lists the seeded file: \(list.output)")

        // --- Bounded live turn: only guarantee is that it terminates. ---
        await engine.start()
        let collector = Task { await lxCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text:
            "Use the write_file tool to create live.txt containing READY, "
            + "then list_dir and read_file to show it.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertNotNil(lxLastTurnStatus(evs),
                        "the bounded live file-tools turn terminated")
    }

    // MARK: 2. web_search real backend (happy)

    /// The real OpenAI web-search backend returns a ranked snippet for a
    /// factual query. Asserted via DIRECT dispatch (model-independent) — the
    /// session model is never involved. Gated on a live key.
    func testWebSearchRealBackendReturnsParis() async throws {
        try lxSkipUnlessLiveKey()
        guard let key = lxAPIKey() else {
            throw XCTSkip("OPENAI_API_KEY not set")
        }

        let home = lxTmp("web-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("web-work"); defer { try? FileManager.default.removeItem(atPath: work) }

        // Register the web_search tool backed by the REAL OpenAI backend.
        let router = ToolRouter(limits: Limits())
        await router.register(WebSearchTool(backend: OpenAIWebSearch(apiKey: key)))

        let result = await router.dispatch(
            ToolCall(callId: "ws1", name: "web_search",
                     argumentsJSON: #"{"query":"capital of France"}"#),
            cwd: work, deadline: .fromNow(.seconds(60)))

        XCTAssertTrue(result.success,
                      "real web_search backend returns success: \(result.output)")
        XCTAssertFalse(result.output.isEmpty,
                       "real web_search returns a non-empty snippet")
        XCTAssertTrue(result.output.lowercased().contains("paris"),
                      "the ranked snippet names the actual answer: \(result.output)")
    }

    // MARK: 3. binary refusal + honest disabled backend (adversarial)

    /// Two refusal paths, both model-independent:
    ///  - read_file actively refuses a file with a NUL byte in the first 4 KB
    ///    rather than returning garbled/binary content.
    ///  - the DEFAULT (disabled) web_search backend fails with the exact
    ///    honest message — never a silent success.
    func testReadFileRefusesBinaryAndDisabledWebSearchFailsCleanly() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("bin-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("bin-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite, writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sb, limits: Limits())

        // --- Seed a binary file: NUL byte within the first 4 KB. ---
        var bytes = [UInt8](repeating: 0x41, count: 1024)  // 'A' padding
        bytes[100] = 0x00                                   // NUL inside the 4 KB sniff window
        let binURL = URL(fileURLWithPath: work + "/bin.dat")
        try Data(bytes).write(to: binURL)

        let read = await router.dispatch(
            ToolCall(callId: "rb1", name: "read_file",
                     argumentsJSON: #"{"path":"bin.dat"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertFalse(read.success,
                       "read_file refuses the binary file rather than succeeding")
        XCTAssertTrue(read.output.contains("binary file refused"),
                      "read_file surfaces the binary-refusal reason: \(read.output)")

        // --- Disabled web_search backend is honest, never a silent success. ---
        let disabledRouter = ToolRouter(limits: Limits())
        await disabledRouter.register(WebSearchTool())  // default == DisabledWebSearch
        let disabled = await disabledRouter.dispatch(
            ToolCall(callId: "dw1", name: "web_search",
                     argumentsJSON: #"{"query":"anything at all"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertFalse(disabled.success,
                       "the disabled web_search backend reports failure, not success")
        XCTAssertEqual(disabled.output,
                       "web_search is not configured for this session",
                       "the disabled path is honest with the exact contract message")
    }
}
