import XCTest
import Foundation
@testable import Supervisor
@testable import Persistence
@testable import ProtocolModel
@testable import WireProtocol
@testable import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private actor SpawnSink {
    private(set) var messages: [JSONRPCMessage] = []
    func append(_ m: JSONRPCMessage) { messages.append(m) }
    func response(id: Int64) -> JSONRPCResponse? {
        for m in messages { if case .response(let r) = m, r.id == .int(id) { return r } }
        return nil
    }
    func sawNotification(_ method: String) -> Bool {
        messages.contains {
            if case .notification(let n) = $0 { return n.method == method }
            return false
        }
    }
}

final class SpawnWorkerTests: XCTestCase {

    private func sessionBinary() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            cwd + "/.build/debug/codex-session",
            cwd + "/.build/x86_64-unknown-linux-gnu/debug/codex-session",
            cwd + "/.build/release/codex-session",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func testRealProcessPerSessionTurnEndToEnd() async throws {
        guard let bin = sessionBinary() else {
            throw XCTSkip("codex-session binary not built at .build/*/codex-session")
        }
        setenv("CODEXKIT_SESSION_BIN", bin, 1)

        let home = NSTemporaryDirectory() + "spawn-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        // The spawned child selects the deterministic mock via CODEXKIT_MOCK.
        let factory = SpawnWorker.factory(codexHome: home,
                                          extraEnv: ["CODEXKIT_MOCK": "1"])
        let supervisor = SessionSupervisor(factory: factory)
        let router = RequestRouter(supervisor: supervisor, store: store,
                                   codexHome: home)
        let conn = InMemoryConnection()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        defer { pump.cancel() }
        let sink = SpawnSink()
        let drain = Task { for await m in conn.clientOutbound() { await sink.append(m) } }
        defer { drain.cancel() }

        func send(_ id: Int, _ method: String, _ params: JSONValue?) {
            conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)),
                                                    method: method, params: params)))
        }
        func awaitResponse(_ id: Int64, timeoutMs: Int) async -> JSONRPCResponse? {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if let r = await sink.response(id: id) { return r }
                try? await Task.sleep(for: .milliseconds(40))
            }
            return nil
        }
        func awaitNotification(_ method: String, timeoutMs: Int) async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if await sink.sawNotification(method) { return true }
                try? await Task.sleep(for: .milliseconds(40))
            }
            return false
        }

        send(1, "initialize", .object(["clientInfo": .object(["name": .string("spawn")])]))
        let r1 = await awaitResponse(1, timeoutMs: 15_000)
        XCTAssertNotNil(r1, "initialize handled")
        conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        send(2, "thread/start", .object(["cwd": .string(home)]))
        guard let sr = await awaitResponse(2, timeoutMs: 15_000),
              let env = try? JSONBridge.decode(ThreadResultEnvelope.self,
                                               from: sr.result) else {
            return XCTFail("thread/start failed (spawned worker did not bind)")
        }
        let tid = env.thread.id

        send(3, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("hi")])]),
        ]))
        let r3 = await awaitResponse(3, timeoutMs: 15_000)
        XCTAssertNotNil(r3, "turn/start acked")
        let completed = await awaitNotification("turn/completed", timeoutMs: 30_000)
        XCTAssertTrue(completed,
                      "the separate codex-session process drove a turn to completion")
        let started = await sink.sawNotification("turn/started")
        XCTAssertTrue(started, "turn/started relayed across the process boundary")
        await supervisor.quiesce(tid)
    }

    func testSpawnedWorkerTerminateReapsForkedDescendant() async throws {
        #if os(macOS) || os(Linux)
        let home = NSTemporaryDirectory() + "spawn-group-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let script = home + "/fake-session.sh"
        let childPIDFile = home + "/child.pid"
        try """
        #!/bin/sh
        sleep 30 &
        echo $! > "$CODEXKIT_CHILD_PID_FILE"
        wait
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                              ofItemAtPath: script)

        let previous = getenv("CODEXKIT_SESSION_BIN").map { String(cString: $0) }
        setenv("CODEXKIT_SESSION_BIN", script, 1)
        defer {
            if let previous {
                setenv("CODEXKIT_SESSION_BIN", previous, 1)
            } else {
                unsetenv("CODEXKIT_SESSION_BIN")
            }
        }

        let factory = SpawnWorker.factory(
            codexHome: home,
            extraEnv: ["CODEXKIT_CHILD_PID_FILE": childPIDFile]
        )
        let handle = await factory(SessionConfig(threadId: ThreadId("thr_spawn_group"), cwd: home))
        guard let rootPID = handle.pid else {
            return XCTFail("spawned worker should expose its root pid")
        }
        let childPID = try await waitForPIDFile(childPIDFile)
        XCTAssertTrue(processExists(rootPID), "worker root should be alive before termination")
        XCTAssertTrue(processExists(childPID), "forked descendant should be alive before termination")

        handle.terminate()
        _ = await handle.task.value
        try await eventuallyProcessGone(rootPID)
        try await eventuallyProcessGone(childPID)
        #else
        throw XCTSkip("process-group containment is only implemented on POSIX platforms")
        #endif
    }

}

#if os(macOS) || os(Linux)
private func waitForPIDFile(_ path: String, timeout: Duration = .seconds(2)) async throws -> Int32 {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("child pid file was not written")
    return -1
}

private func processExists(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno != ESRCH
}

private func eventuallyProcessGone(_ pid: Int32, timeout: Duration = .seconds(3)) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if !processExists(pid) { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("process \(pid) was still alive after termination")
}
#endif
