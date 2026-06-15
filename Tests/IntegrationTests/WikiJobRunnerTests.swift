import XCTest
@testable import Supervisor

/// The subprocess streaming core behind wiki/research/start + wiki/ingest/start:
/// each stdout line is delivered to `onLine` as it arrives, in order, and the exit
/// code is returned. Uses a temp script standing in for the codex-memory CLI.
final class WikiJobRunnerTests: XCTestCase {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var v: [String] = []
        func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return v }
    }

    private func writeScript(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "wikijob-\(UUID().uuidString).sh"
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testStreamsNDJSONLinesInOrder() async throws {
        let script = try writeScript(#"""
        printf '{"type":"event","kind":"started"}\n'
        printf '{"type":"event","kind":"round_started","round":1}\n'
        printf '{"type":"result","status":"completed","rounds":1}\n'
        exit 0
        """#)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let lines = Lines()
        let exit = await WikiJobRunner.stream(executable: script, args: []) { lines.add($0) }
        XCTAssertEqual(exit, 0)
        let all = lines.all
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all[0].contains("\"started\""))
        XCTAssertTrue(all[1].contains("\"round_started\""))
        XCTAssertTrue(all[2].contains("\"result\""))
        XCTAssertTrue(all[2].contains("\"completed\""))
    }

    func testNonZeroExitSurfaced() async throws {
        let script = try writeScript("printf '{\"type\":\"event\"}\\n'; exit 3")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let lines = Lines()
        let exit = await WikiJobRunner.stream(executable: script, args: []) { lines.add($0) }
        XCTAssertEqual(exit, 3)
        XCTAssertEqual(lines.all.count, 1)
    }

    func testMissingExecutableReturnsNil() async throws {
        let exit = await WikiJobRunner.stream(executable: "/no/such/binary-zzz", args: []) { _ in }
        XCTAssertNil(exit)
    }

    func testCodexMemoryPathResolvesNextToSelf() {
        // Default resolution: the env override wins; otherwise it's co-located.
        setenv("CODEX_MEMORY_BIN", "/custom/codex-memory", 1)
        XCTAssertEqual(WikiJobRunner.codexMemoryPath(), "/custom/codex-memory")
        unsetenv("CODEX_MEMORY_BIN")
        XCTAssertTrue(WikiJobRunner.codexMemoryPath().hasSuffix("/codex-memory"))
    }
}
