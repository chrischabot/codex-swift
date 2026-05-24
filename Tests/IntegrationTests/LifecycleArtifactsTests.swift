import XCTest
import Foundation

final class LifecycleArtifactsTests: XCTestCase {

    func testLifecycleRenderProducesLaunchdPlistsEntitlementsAndRunbook() throws {
        let root = FileManager.default.currentDirectoryPath
        let out = NSTemporaryDirectory() + "codexkit-lifecycle-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: out) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.arguments = [
            "scripts/codexkit-lifecycle.sh",
            "render",
            "--output", out,
            "--install-root", "/Applications/CodexKit",
            "--codex-home", "/Users/tester/.codex",
            "--label-prefix", "ai.igent.codexkit.tests",
            "--listen", "unix://",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self))

        let codexd = try plist(out + "/LaunchAgents/ai.igent.codexkit.tests.codexd.plist")
        XCTAssertEqual(codexd["Label"] as? String, "ai.igent.codexkit.tests.codexd")
        XCTAssertEqual(codexd["KeepAlive"] as? Bool, true)
        XCTAssertEqual(codexd["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(codexd["ThrottleInterval"] as? Int, 5)
        XCTAssertEqual(codexd["ProgramArguments"] as? [String],
                       ["/Applications/CodexKit/bin/codexd", "--listen", "unix://"])
        let env = try XCTUnwrap(codexd["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["CODEX_HOME"], "/Users/tester/.codex")
        XCTAssertEqual(env["CODEX_BROKER_AUTH_STORE"],
                       "/Users/tester/.codex/broker-auth.json")
        XCTAssertEqual(env["CODEXKIT_SESSION_BIN"],
                       "/Applications/CodexKit/bin/codex-session")

        let broker = try plist(out + "/LaunchAgents/ai.igent.codexkit.tests.codex-broker.plist")
        XCTAssertEqual(broker["Label"] as? String, "ai.igent.codexkit.tests.codex-broker")
        XCTAssertEqual(broker["ProgramArguments"] as? [String],
                       ["/Applications/CodexKit/bin/codex-broker",
                        "--listen", "unix:///Users/tester/.codex/broker.sock"])
        XCTAssertEqual(broker["KeepAlive"] as? Bool, true)

        for name in ["codexd", "codex-broker", "codex-session"] {
            let entitlements = try plist(out + "/entitlements/\(name).entitlements")
            XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
            XCTAssertEqual(entitlements["com.apple.security.network.server"] as? Bool, true)
            XCTAssertEqual(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool, false)
        }

        let runbook = try String(contentsOfFile: out + "/runbooks/sign-notarize.md",
                                 encoding: .utf8)
        XCTAssertTrue(runbook.contains("codesign --force --options runtime"))
        XCTAssertTrue(runbook.contains("xcrun notarytool submit --wait"))
        XCTAssertTrue(runbook.contains("launchctl bootstrap"))

        let operations = try String(contentsOfFile: out + "/runbooks/operations.md",
                                    encoding: .utf8)
        XCTAssertTrue(operations.contains("ai.igent.codexkit.tests.codexd"))
        XCTAssertTrue(operations.contains("ai.igent.codexkit.tests.codex-broker"))
        XCTAssertTrue(operations.contains("launchctl print \"gui/"))
        XCTAssertTrue(operations.contains("launchctl kickstart -k"))
        XCTAssertTrue(operations.contains("launchctl bootout"))
        XCTAssertTrue(operations.contains("app-server-control/app-server-control.sock"))
        XCTAssertTrue(operations.contains("/Users/tester/.codex/broker.sock"))
        XCTAssertTrue(operations.contains("/Users/tester/.codex/broker-auth.json"))
        XCTAssertTrue(operations.contains("/Applications/CodexKit/logs/codexd.err.log"))
        XCTAssertTrue(operations.contains("/Applications/CodexKit/logs/codex-broker.err.log"))
        XCTAssertTrue(operations.contains("stage-release --install-root \"/Applications/CodexKit\""))
        XCTAssertTrue(operations.contains("promote-worker --install-root \"/Applications/CodexKit\" --release <new-release>"))
        XCTAssertTrue(operations.contains("promote-worker --install-root \"/Applications/CodexKit\" --release <previous-release>"))
        XCTAssertTrue(operations.contains("/Applications/CodexKit/current-worker-release"))
        XCTAssertTrue(operations.contains("tools/e2e/g6_poison_worker.sh"))
        XCTAssertTrue(operations.contains("tools/e2e/g9_final_rehearsal.sh"))
        XCTAssertTrue(operations.contains("verify_release_evidence.py --evidence-dir \"$CODEXKIT_EVIDENCE_DIR\" --strict"))
        XCTAssertTrue(operations.contains("--purge-codex-home"))
    }

    func testLifecycleStageInstallCopiesBuiltBinariesAndPointsPlistsAtStage() throws {
        let root = FileManager.default.currentDirectoryPath
        let build = NSTemporaryDirectory() + "codexkit-build-" + UUID().uuidString
        let stage = NSTemporaryDirectory() + "codexkit-stage-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: build)
            try? FileManager.default.removeItem(atPath: stage)
        }
        try FileManager.default.createDirectory(atPath: build,
                                                withIntermediateDirectories: true)
        for name in ["codexd", "codex-broker", "codex-session"] {
            let path = build + "/" + name
            try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true,
                                            encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                  ofItemAtPath: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.arguments = [
            "scripts/codexkit-lifecycle.sh",
            "stage-install",
            "--destdir", stage,
            "--install-root", "/Library/Application Support/CodexKit",
            "--build-dir", build,
            "--codex-home", "/tmp/codex-home",
            "--mock-model",
            "--mock-slow-ms", "1234",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self))

        let stagedRoot = stage + "/Library/Application Support/CodexKit"
        for name in ["codexd", "codex-broker", "codex-session"] {
            let binary = stagedRoot + "/bin/" + name
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary),
                          "expected staged executable \(binary)")
        }

        let codexd = try plist(stage + "/LaunchAgents/ai.igent.codexkit.codexd.plist")
        let args = try XCTUnwrap(codexd["ProgramArguments"] as? [String])
        XCTAssertEqual(args.first, stagedRoot + "/bin/codexd")
        let env = try XCTUnwrap(codexd["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["CODEXKIT_SESSION_BIN"], stagedRoot + "/bin/codex-session")
        XCTAssertEqual(env["CODEX_BROKER_AUTH_STORE"], "/tmp/codex-home/broker-auth.json")
        XCTAssertEqual(env["CODEXKIT_MOCK"], "1")
        XCTAssertEqual(env["CODEXKIT_MOCK_SLOW_MS"], "1234")

        let operations = try String(contentsOfFile: stage + "/runbooks/operations.md",
                                    encoding: .utf8)
        XCTAssertTrue(operations.contains("Runtime root for rendered plists: `\(stagedRoot)`"))
        XCTAssertTrue(operations.contains("session worker binary: `\(stagedRoot)/bin/codex-session`"))
        XCTAssertTrue(operations.contains("CODEXKIT_SESSION_BIN=\(stagedRoot)/bin/codex-session"))
        XCTAssertTrue(operations.contains("CODEX_HOME: `/tmp/codex-home`"))
        XCTAssertTrue(operations.contains("/tmp/codex-home/broker.sock"))
    }

    func testLifecycleInstallStatusAndUninstallUseExplicitTempRoots() throws {
        let root = FileManager.default.currentDirectoryPath
        let build = NSTemporaryDirectory() + "codexkit-build-" + UUID().uuidString
        let installRoot = NSTemporaryDirectory() + "codexkit-install-" + UUID().uuidString
        let launchAgents = NSTemporaryDirectory() + "codexkit-agents-" + UUID().uuidString
        let codexHome = NSTemporaryDirectory() + "codexkit-home-" + UUID().uuidString
        let label = "ai.igent.codexkit.tests." + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: build)
            try? FileManager.default.removeItem(atPath: installRoot)
            try? FileManager.default.removeItem(atPath: launchAgents)
            try? FileManager.default.removeItem(atPath: codexHome)
        }
        try FileManager.default.createDirectory(atPath: build,
                                                withIntermediateDirectories: true)
        for name in ["codexd", "codex-broker", "codex-session"] {
            let path = build + "/" + name
            try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true,
                                            encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                  ofItemAtPath: path)
        }

        _ = try runLifecycle(root: root, [
            "install",
            "--install-root", installRoot,
            "--launch-agents-dir", launchAgents,
            "--build-dir", build,
            "--codex-home", codexHome,
            "--label-prefix", label,
            "--launch-domain", "gui/999999",
            "--no-bootstrap",
            "--mock-model",
        ])
        try FileManager.default.createDirectory(atPath: codexHome,
                                                withIntermediateDirectories: true)
        try "state".write(toFile: codexHome + "/state-marker",
                          atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installRoot + "/bin/codexd"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installRoot + "/bin/codex-broker"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installRoot + "/bin/codex-session"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchAgents + "/\(label).codexd.plist"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchAgents + "/\(label).codex-broker.plist"))

        let status = try runLifecycle(root: root, [
            "status",
            "--install-root", installRoot,
            "--launch-agents-dir", launchAgents,
            "--label-prefix", label,
            "--launch-domain", "gui/999999",
        ])
        XCTAssertTrue(status.contains("installed=yes"))
        XCTAssertTrue(status.contains("\(label).codexd=not-loaded"))
        XCTAssertTrue(status.contains("\(label).codex-broker=not-loaded"))

        _ = try runLifecycle(root: root, [
            "uninstall",
            "--install-root", installRoot,
            "--launch-agents-dir", launchAgents,
            "--codex-home", codexHome,
            "--label-prefix", label,
            "--launch-domain", "gui/999999",
            "--purge-codex-home",
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgents + "/\(label).codexd.plist"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgents + "/\(label).codex-broker.plist"))

        let finalStatus = try runLifecycle(root: root, [
            "status",
            "--install-root", installRoot,
            "--launch-agents-dir", launchAgents,
            "--label-prefix", label,
            "--launch-domain", "gui/999999",
        ])
        XCTAssertTrue(finalStatus.contains("installed=no"))
    }

    func testLifecycleVersionedReleasePromotesWorkerSymlink() throws {
        let root = FileManager.default.currentDirectoryPath
        let build = NSTemporaryDirectory() + "codexkit-build-" + UUID().uuidString
        let installRoot = NSTemporaryDirectory() + "codexkit-versioned-" + UUID().uuidString
        let launchAgents = NSTemporaryDirectory() + "codexkit-agents-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: build)
            try? FileManager.default.removeItem(atPath: installRoot)
            try? FileManager.default.removeItem(atPath: launchAgents)
        }
        try FileManager.default.createDirectory(atPath: build,
                                                withIntermediateDirectories: true)
        for name in ["codexd", "codex-broker", "codex-session"] {
            let path = build + "/" + name
            try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true,
                                            encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                  ofItemAtPath: path)
        }

        _ = try runLifecycle(root: root, [
            "install",
            "--install-root", installRoot,
            "--launch-agents-dir", launchAgents,
            "--build-dir", build,
            "--release", "blue",
            "--no-bootstrap",
        ])
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: installRoot + "/releases/blue/bin/codex-session"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: installRoot + "/bin/codex-session"),
                       "../releases/blue/bin/codex-session")

        _ = try runLifecycle(root: root, [
            "stage-release",
            "--install-root", installRoot,
            "--build-dir", build,
            "--release", "green",
        ])
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: installRoot + "/releases/green/bin/codex-session"))

        let promoted = try runLifecycle(root: root, [
            "promote-worker",
            "--install-root", installRoot,
            "--release", "green",
        ])
        XCTAssertTrue(promoted.contains("promoted worker release green"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: installRoot + "/bin/codex-session"),
                       "../releases/green/bin/codex-session")
        XCTAssertEqual(try String(contentsOfFile: installRoot + "/current-worker-release",
                                  encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       "green")

        _ = try runLifecycle(root: root, [
            "promote-worker",
            "--install-root", installRoot,
            "--release", "blue",
        ])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: installRoot + "/bin/codex-session"),
                       "../releases/blue/bin/codex-session")
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let value = try PropertyListSerialization.propertyList(from: data,
                                                               options: [],
                                                               format: nil)
        return try XCTUnwrap(value as? [String: Any], "not a dictionary plist: \(path)")
    }

    private func runLifecycle(root: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.arguments = ["scripts/codexkit-lifecycle.sh"] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, err)
        return out
    }
}
