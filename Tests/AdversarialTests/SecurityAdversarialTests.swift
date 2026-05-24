import XCTest
import Foundation
@testable import Persistence
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import HarnessCore
@testable import ModelClient
@testable import Tools
@testable import Sandbox

private func saTmp(_ tag: String) -> String {
    let p = NSTemporaryDirectory() + "sa-\(tag)-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private func saCollect(_ e: SessionEngine, untilCompletions n: Int = 1,
                        timeout: Duration = .seconds(30)) async -> [ServerNotification] {
    let s = await e.events()
    let c = Task { () -> [ServerNotification] in
        var o: [ServerNotification] = []
        var k = 0
        for await ev in s {
            o.append(ev)
            if case .turnCompleted = ev { k += 1; if k == n { break } }
        }
        return o
    }
    let t = Task { try? await Task.sleep(for: timeout); c.cancel() }
    let r = await c.value
    t.cancel()
    return r
}

final class SecurityAdversarialTests: XCTestCase {

    // MARK: ThreadId well-formedness matrix (CWE-22/CWE-23 defense)

    func testThreadIdWellFormednessMatrix() {
        // Generated ids are always safe.
        for _ in 0..<200 { XCTAssertTrue(ThreadId.generate().isWellFormed) }
        let safe = ["thr_abc", "a", "A1_-.", "thr_0e8400-e29b-41d4-a716",
                    String(repeating: "z", count: 256)]
        for s in safe { XCTAssertTrue(ThreadId(s).isWellFormed, "should accept \(s)") }
        let hostile = [
            "", ".", "..", "../x", "../../../../tmp/evil", "a/b", "a\\b",
            "x/../../y", "foo..bar", "..hidden", "trailing..", "a b",
            "tab\tid", "nl\nid", "nul\u{0000}id", "ctrl\u{0001}",
            "rtl\u{202E}evil", "emoji😀", "résumé", "ＡＢＣ",            // fullwidth
            "a:b", "a;b", "a|b", "a*b", "a?b", "$(whoami)", "`id`",
            String(repeating: "a", count: 257),
        ]
        for s in hostile {
            XCTAssertFalse(ThreadId(s).isWellFormed, "must reject \(s.debugDescription)")
        }
    }

    // MARK: ThreadStore path traversal is contained at the store boundary

    func testThreadStorePathTraversalContained() async throws {
        let home = saTmp("home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let marker = "codexkit_pwn_\(UUID().uuidString)"
        let escapes = [
            "../../../../tmp/\(marker)",
            "../../\(marker)",
            "a/b/\(marker)",
            "..",
            "nul\u{0000}\(marker)",
        ]
        for e in escapes {
            let id = ThreadId(e)
            // create / reconstruct / rollback / quiesce / durabilityBarrier
            // must all refuse an unsafe id (no path is ever derived).
            do { _ = try await store.create(SessionConfig(threadId: id, cwd: "/w"))
                 XCTFail("create accepted unsafe id \(e)") } catch {}
            do { _ = try await store.reconstruct(id)
                 XCTFail("reconstruct accepted unsafe id \(e)") } catch {}
            do { _ = try await store.rollback(id, numTurns: 1)
                 XCTFail("rollback accepted unsafe id \(e)") } catch {}
            do { try await store.durabilityBarrier(id)
                 XCTFail("durabilityBarrier accepted unsafe id \(e)") } catch {}
            do { try await store.quiesce(id)
                 XCTFail("quiesce accepted unsafe id \(e)") } catch {}
        }
        // Crucially: nothing was ever written outside the codex home.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: "/tmp/\(marker).rollout.jsonl"),
            "a traversal id must never create a file outside CODEX_HOME")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/\(marker)"))
        // A well-formed id still works normally (no false positives).
        let good = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: good, cwd: "/w"))
        let rebuilt = try await store.reconstruct(good)
        XCTAssertEqual(rebuilt.config.threadId, good)
    }

    // MARK: SQL injection is stored as inert data (parameterized binds)

    func testStateDBInjectionIsDataOnly() async throws {
        let home = saTmp("sqli"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let a = ThreadId.generate(); let b = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: a, cwd: "/a"))
        _ = try await store.create(SessionConfig(threadId: b, cwd: "/b"))
        let evilName = "\"; DROP TABLE threads;-- '"
        let evilObjective = "' OR '1'='1'; DELETE FROM goals; --"
        try await store.setName(a, evilName)
        _ = try await store.goalSet(a, objective: evilObjective,
                                    status: .active, tokenBudget: .some(100))
        // Tables intact, values stored verbatim — injection was inert.
        let listed = try await store.list(archived: false, limit: 100)
        XCTAssertEqual(Set(listed.map { $0.id }), Set([a, b]),
                       "DROP/DELETE injection did not execute (both threads survive)")
        let n = try await store.name(a)
        XCTAssertEqual(n, evilName, "name stored verbatim (bound, not interpolated)")
        let g = try await store.goalGet(a)
        XCTAssertEqual(g?.objective, evilObjective, "objective stored verbatim")
    }

    // MARK: Rollout cannot be forged via embedded newlines / control bytes

    func testRolloutNewlineAndControlNonForging() async throws {
        let home = saTmp("roll"); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: Limits())
        let forge = "hello\n"
            + #"{"t":"turnBoundary","turnId":"evil","status":"completed"}"#
            + "\nworld\u{0000}\u{0001}\u{007F}\t\r end"
        let tid = TurnId("t1")
        try await w.append(.item(turnId: tid, item: .agentMessage(id: ItemId("a"), text: forge)))
        _ = try await w.durabilityBarrier()
        await w.close()
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 1, "embedded newline must not forge a 2nd record")
        guard case .item(_, .agentMessage(_, let back))? = recs.first else {
            return XCTFail("expected a single agentMessage record")
        }
        XCTAssertEqual(back, forge, "content round-trips byte-exact (JSON-escaped)")
        // And no spurious turnBoundary was injected.
        XCTAssertFalse(recs.contains {
            if case .turnBoundary = $0 { return true }; return false
        })
    }

    // MARK: Mailbox is bounded under a flood (Codex F-1 analog, hardened)

    func testMailboxBoundedUnderFlood() async {
        let mb = Mailbox(capacity: 64)
        for i in 0..<100_000 {
            _ = await mb.send(InterAgentCommunication(
                author: "/root", recipient: "/root",
                content: "m\(i)", triggerTurn: i % 2 == 0))
        }
        let dropped = await mb.droppedCount
        XCTAssertGreaterThan(dropped, 0, "flood beyond capacity drops oldest")
        let curSeq = await mb.currentSeq()
        XCTAssertEqual(curSeq, 100_000, "seq is monotonic, not bounded")
        let drained = await mb.drain()
        XCTAssertLessThanOrEqual(drained.count, 64, "queue never exceeds capacity")
        XCTAssertEqual(drained.last?.content, "m99999", "newest survives, in order")
        let stillPending = await mb.hasPending()
        XCTAssertFalse(stillPending, "drain clears the bounded window")
    }

    // MARK: SessionEngine sheds a pending-steer-input flood (CWE-400)

    func testSessionEnginePendingSteerFloodIsShed() async throws {
        let home = saTmp("steer"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        var lim = Limits(); lim.maxPendingTurnInputs = 8
        // A slow first turn keeps the loop inside one sampling iteration so
        // pendingInput accumulates while we flood it.
        let model = MockModelClient([
            MockScenario([.created, .slowMillis(600),
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r", tokens: 1)]),
            .hello("after"),
        ], limits: lim)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: lim), limits: lim)
        await engine.start()
        let collector = Task { await saCollect(engine, untilCompletions: 1,
                                               timeout: .seconds(20)) }
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil))
        try await Task.sleep(for: .milliseconds(50))
        for i in 0..<5000 {
            await engine.submit(.steer(input: [TurnInput(text: "steer-\(i)")],
                                       expectedTurnId: TurnId("x")))
        }
        let evs = await collector.value
        let overloaded = evs.contains {
            if case .error(_, _, _, let b) = $0 { return b.codexErrorInfo == "Overloaded" }
            return false
        }
        XCTAssertTrue(overloaded,
                      "a steer flood is shed with a clean Overloaded error (bounded memory)")
        XCTAssertTrue(evs.contains { if case .turnCompleted = $0 { return true }; return false },
                      "the session stays responsive (turn still completes) under the flood")
    }

    // MARK: apply_patch symlink-escape containment (CWE-59)

    func testApplyPatchSymlinkEscapeBlocked() throws {
        let root = saTmp("aproot"); defer { try? FileManager.default.removeItem(atPath: root) }
        let outsideDir = saTmp("apout")
        defer { try? FileManager.default.removeItem(atPath: outsideDir) }
        let secretDir = saTmp("apsecret")
        defer { try? FileManager.default.removeItem(atPath: secretDir) }
        try "TOP-SECRET".write(toFile: secretDir + "/secret.txt",
                               atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/linkdir", withDestinationPath: outsideDir)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/passwd", withDestinationPath: secretDir + "/secret.txt")
        let ap = ApplyPatch()

        // 1. Add through a symlinked directory → blocked, nothing written out.
        let addThroughLink = """
        *** Begin Patch
        *** Add File: linkdir/evil.txt
        +pwned
        *** End Patch
        """
        XCTAssertThrowsError(try ap.apply(addThroughLink, root: root)) {
            guard case ApplyPatchError.unsafePath = $0 else {
                return XCTFail("expected unsafePath, got \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDir + "/evil.txt"),
                       "symlinked-dir add must not escape the workspace")

        // 2. Update a symlinked target file → blocked, secret unchanged.
        let updateSymlinkedFile = """
        *** Begin Patch
        *** Update File: passwd
        @@
        -TOP-SECRET
        +HACKED
        *** End Patch
        """
        XCTAssertThrowsError(try ap.apply(updateSymlinkedFile, root: root)) {
            guard case ApplyPatchError.unsafePath = $0 else {
                return XCTFail("expected unsafePath, got \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOfFile: secretDir + "/secret.txt",
                                  encoding: .utf8), "TOP-SECRET",
                       "symlinked-file update must not modify the target")

        // 3. Delete through a symlinked directory → blocked.
        try "keep".write(toFile: outsideDir + "/keep.txt",
                         atomically: true, encoding: .utf8)
        let deleteThroughLink = """
        *** Begin Patch
        *** Delete File: linkdir/keep.txt
        *** End Patch
        """
        XCTAssertThrowsError(try ap.apply(deleteThroughLink, root: root)) {
            guard case ApplyPatchError.unsafePath = $0 else {
                return XCTFail("expected unsafePath, got \($0)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDir + "/keep.txt"),
                      "symlinked-dir delete must not remove the external file")

        // 4. A legitimate nested add inside the real root still works.
        let legit = """
        *** Begin Patch
        *** Add File: sub/dir/ok.txt
        +fine
        *** End Patch
        """
        let applied = try ap.apply(legit, root: root)
        XCTAssertEqual(applied.first?.kind, .add)
        XCTAssertEqual(try String(contentsOfFile: root + "/sub/dir/ok.txt",
                                  encoding: .utf8), "fine",
                       "containment must not break legitimate in-workspace writes")
    }

    func testApplyPatchAbsoluteAndTraversalStillRejected() throws {
        let root = saTmp("aptr"); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        XCTAssertThrowsError(try ap.parse(
            "*** Begin Patch\n*** Add File: /etc/cron.d/evil\n+x\n*** End Patch")) {
            guard case ApplyPatchError.unsafePath = $0 else { return XCTFail() }
        }
        XCTAssertThrowsError(try ap.parse(
            "*** Begin Patch\n*** Delete File: ../../etc/passwd\n*** End Patch")) {
            guard case ApplyPatchError.unsafePath = $0 else { return XCTFail() }
        }
        _ = root
    }
}