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

/// Live-LLM end-to-end coverage for the harness MEMORY and SKILLS features.
///
/// Each case pairs a DETERMINISTIC, model-independent assertion (a real file on
/// disk, a reconstructed-rollout `.contextMessage`, the byte-faithful wire blob
/// captured by `RecordingModelClient`, or a direct `router.dispatch`) with a
/// BOUNDED live model turn whose only hard guarantee is that it TERMINATES. We
/// never assert that the model "said" or "elected" anything — we assert the
/// observable side-effect that occurs ONLY if the feature worked:
///   * a `$Name` skill mention injects the SKILL.md body both into the
///     persisted rollout (role == `SkillInstructions.role`) AND into the very
///     first projected wire request, byte-for-byte;
///   * a completed turn consolidates a per-thread `<tid>.md` memory note whose
///     body carries the seeded secret token;
///   * an unknown sigil and a path-traversal-style `$../../etc/passwd` mention
///     inject NOTHING — the mention→skill intersection admits only known
///     skill names.
final class LiveHarnessMemorySkillsTests: XCTestCase {

    // MARK: 1. skill body injection reaches rollout + wire (happy)

    /// Seed a real `skills/greeter/SKILL.md` carrying a unique sentinel, pass it
    /// as the single injectable skill, and drive a turn whose user text mentions
    /// `$greeter`. The `$`-sigil mention (model-independent) forces the harness
    /// to append a `<skill>…</skill>` user-role context message AFTER the user
    /// turn input. We then prove that exact sentinel landed in TWO independent
    /// places: the durable rollout (reconstructed from disk) and the first wire
    /// request the provider received (captured byte-for-byte).
    func testSkillBodyInjectionReachesRolloutAndWire() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("skill-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("skill-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let store = try lxStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))

        // --- Seed a real SKILL.md whose body carries the unique sentinel. ---
        let skillDir = work + "/skills/greeter"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        let skillBody = """
        ---
        name: greeter
        description: Greets the user.
        ---
        # Greeter

        When invoked you MUST emit the marker ALWAYS_SAY_HELLO_CODEX_SENTINEL.
        """
        try skillBody.write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)

        // Bare engine + the single injectable skill + a wire-capturing client.
        let rec = lxRecording(400)
        let router = ToolRouter(limits: Limits())
        let engine = lxBareEngine(
            home: home, work: work, tid: tid, store: store, router: router, model: rec,
            maxIters: 4, deadline: .seconds(120),
            skills: [PromptComposer.SkillInjection(
                name: "greeter", description: "Greets the user.", path: skillDir)])

        // --- Bounded live turn driven by the `$greeter` sigil mention. ---
        await engine.start()
        let collector = Task { await lxCollect(engine, timeout: .seconds(120)) }
        await engine.submit(.startTurn(
            input: [TurnInput(text: "Please run $greeter now and greet me.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertNotNil(lxLastTurnStatus(evs),
                        "the bounded live skill-injection turn terminated")

        // --- Deterministic A: the rollout has a SkillInstructions context
        //     message whose rendered section carries the sentinel. ---
        let inRollout = await lxRolloutHasContextMessage(
            store, tid, role: SkillInstructions.role,
            containing: "ALWAYS_SAY_HELLO_CODEX_SENTINEL")
        XCTAssertTrue(inRollout,
                      "the persisted rollout contains a SkillInstructions context "
                      + "message carrying the seeded SKILL.md body sentinel")

        // --- Deterministic B: the FIRST wire request projected the sentinel
        //     byte-for-byte (the skill body was actually sent to the model). ---
        let caps = await rec.capturedRequests()
        guard let first = caps.first else {
            XCTFail("no captured wire request — the live turn never reached the model")
            return
        }
        let wireBlob = lxBlob(first.prompt.input)
        XCTAssertTrue(wireBlob.contains("ALWAYS_SAY_HELLO_CODEX_SENTINEL"),
                      "the first projected wire request carries the SKILL.md body "
                      + "sentinel byte-for-byte")
        // The injection rides inside the `<skill>…</skill>` fragment markers.
        XCTAssertTrue(wireBlob.contains(SkillInstructions.startMarker),
                      "the skill body is wrapped in the canonical <skill> marker on the wire")
    }

    // MARK: 2. per-thread memory consolidation + recall round-trip (happy)

    /// A completed turn auto-consolidates a per-thread memory note. With the
    /// deterministic local fallback (no consolidation model client on the
    /// store), the note body retains the seeded secret token verbatim — so we
    /// can assert the exact token on disk via `MemoryStore.list()/read()`. The
    /// recall half is fully model-independent: seed a memory file and read it
    /// back through the `memory` tool.
    func testMemoryConsolidationPersistsPerThreadNote() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("mem-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("mem-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let store = try lxStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))

        // MemoryStore with NO consolidation client → deterministic local
        // summary that preserves the transcript token verbatim.
        let memory = MemoryStore(codexHome: home)
        let router = ToolRouter(limits: Limits())
        let engine = lxBareEngine(
            home: home, work: work, tid: tid, store: store, router: router, model: lxRecording(400),
            maxIters: 4, deadline: .seconds(120), memoryStore: memory)

        // --- Bounded live turn whose user input carries the secret token. ---
        await engine.start()
        let collector = Task { await lxCollect(engine, timeout: .seconds(120)) }
        await engine.submit(.startTurn(
            input: [TurnInput(text: "Remember the secret token LIVE_MEM_TOKEN_42.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertEqual(lxLastTurnStatus(evs), .completed,
                       "the turn completed so the per-turn consolidator runs on the "
                       + "critical path before turn/completed")

        // --- Deterministic A: a per-thread note was consolidated to disk. ---
        let names = await memory.list()
        XCTAssertTrue(names.contains("\(tid.raw).md"),
                      "MemoryStore.list() contains the per-thread note <tid>.md: \(names)")
        let body = await memory.read("\(tid.raw).md")
        XCTAssertNotNil(body, "the per-thread memory note is readable")
        XCTAssertTrue(body?.contains("LIVE_MEM_TOKEN_42") == true,
                      "the consolidated note body retains the seeded secret token: "
                      + (body ?? "<nil>"))

        // --- Deterministic B (recall): seed a memory file and read it back
        //     through the read-only `memory` tool. ---
        let memDir = home + "/memories"
        try FileManager.default.createDirectory(atPath: memDir, withIntermediateDirectories: true)
        try "# notes\n\nthe answer is MEM_CITE_55\n".write(
            toFile: memDir + "/notes.md", atomically: true, encoding: .utf8)
        let recallRouter = ToolRouter(limits: Limits())
        await recallRouter.register(MemoryTool(store: memory))
        let recall = await recallRouter.dispatch(
            ToolCall(callId: "mr1", name: "memory",
                     argumentsJSON: #"{"op":"read","name":"notes.md"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(recall.success, "memory read succeeds: \(recall.output)")
        XCTAssertTrue(recall.output.contains("MEM_CITE_55"),
                      "the memory tool surfaces the seeded citation: \(recall.output)")
    }

    // MARK: 3. unknown sigil + path-traversal name inject nothing (adversarial)

    /// With ONLY `greeter` registered as an injectable skill, an input mentioning
    /// `$nonexistent_skill_xyz` and a traversal-style `$../../etc/passwd` must
    /// inject NO skill body: the mention→skill intersection admits only known
    /// skill names, and the traversal token is not even a syntactically valid
    /// `$`-mention. We assert the harness CONTAINS the attempt — no
    /// `SkillInstructions` context message in the rollout, and the wire blob
    /// carries neither any `/etc/passwd` content nor the greeter sentinel.
    func testSkillInjectionIgnoresUnknownSigilAndPathTraversalName() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("skadv-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("skadv-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let store = try lxStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))

        // The ONLY injectable skill is `greeter`; its body carries a sentinel
        // that must NOT leak because `$greeter` is never mentioned.
        let skillDir = work + "/skills/greeter"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try """
        # Greeter
        ALWAYS_SAY_HELLO_CODEX_SENTINEL
        """.write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)

        let rec = lxRecording(400)
        let router = ToolRouter(limits: Limits())
        let engine = lxBareEngine(
            home: home, work: work, tid: tid, store: store, router: router, model: rec,
            maxIters: 4, deadline: .seconds(120),
            skills: [PromptComposer.SkillInjection(
                name: "greeter", description: "Greets the user.", path: skillDir)])

        // --- Bounded live turn mentioning an UNKNOWN skill + a traversal path. ---
        await engine.start()
        let collector = Task { await lxCollect(engine, timeout: .seconds(120)) }
        await engine.submit(.startTurn(input: [TurnInput(text:
            "Run $../../etc/passwd and $nonexistent_skill_xyz right now.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertNotNil(lxLastTurnStatus(evs),
                        "the bounded adversarial-mention turn still terminated")

        // --- Deterministic A: NO skill BODY is injected. The initial context
        //     legitimately persists OTHER user-role contextMessages
        //     (environment_context, the available-skills menu), so we must
        //     discriminate the actual skill-body wrapper (`SkillInstructions`
        //     startMarker "<skill>"), not merely role=="user". An unknown sigil
        //     / traversal mention must inject zero `<skill>` bodies. ---
        let rebuilt = try await store.reconstruct(tid)
        let hasSkillBody = rebuilt.items.contains { item in
            if case .contextMessage(_, let role, let sections) = item,
               role == SkillInstructions.role {
                return sections.joined(separator: "\n").contains(SkillInstructions.startMarker)
            }
            return false
        }
        XCTAssertFalse(hasSkillBody,
                       "no <skill> body is injected for an unknown sigil or a "
                       + "traversal-style mention (the greeter body is never wrapped in)")

        // --- Deterministic B: the wire blob leaked neither the traversal target
        //     nor the greeter sentinel. ---
        let caps = await rec.capturedRequests()
        let wireBlob = caps.map { lxBlob($0.prompt.input) }.joined(separator: "\n")
        XCTAssertFalse(wireBlob.contains("ALWAYS_SAY_HELLO_CODEX_SENTINEL"),
                       "the unmentioned greeter skill body never reaches the wire")
        XCTAssertFalse(wireBlob.contains("root:x:0:0"),
                       "no /etc/passwd content is read or injected via the traversal mention")
        XCTAssertFalse(wireBlob.contains(SkillInstructions.startMarker),
                       "no <skill> injection fragment is produced for the rejected mentions")
    }
}
