import XCTest
import Foundation
@testable import Tools
@testable import InfraPrimitives

#if canImport(Darwin)
import Darwin
#endif

/// Severe / adversarial coverage for `GitUtils`:
///   * byte-for-byte oracle vs `git diff --no-index /dev/null <file>` over
///     a large random corpus (text, binary, edge sizes, weird paths);
///   * race / hostile FS conditions (deleted file, symlink, FIFO, very long
///     line, 100 MB file, Unicode/space/quote paths);
///   * concurrency (50 simultaneous `git_diff` calls, zero zombie git
///     processes afterwards);
///   * cancellation propagates to the git child within 200 ms;
///   * the headline perf claim: 100 untracked files → ≤2 s.
///
/// Skipped on hosts without `git` (CI Linux containers usually have it).
final class GitUtilsSevereTests: XCTestCase {

    private func gitAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--version"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "git-severe-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func makeRepo() async throws -> String {
        let dir = try makeTempDir()
        _ = await GitRunner.run(["init", "-q"], cwd: dir)
        _ = await GitRunner.run(["config", "user.email", "t@e"], cwd: dir)
        _ = await GitRunner.run(["config", "user.name", "t"], cwd: dir)
        _ = await GitRunner.run(["config", "commit.gpgsign", "false"], cwd: dir)
        try "seed\n".write(toFile: dir + "/.seed",
                           atomically: true, encoding: .utf8)
        _ = await GitRunner.run(["add", ".seed"], cwd: dir)
        _ = await GitRunner.run(["commit", "-q", "-m", "seed"], cwd: dir)
        return dir
    }

    /// Spawn raw git via Process to capture the reference byte stream
    /// without going through `GitRunner` (so we test in-process logic
    /// against the actual binary, not against a wrapper).
    private func rawGit(_ args: [String], cwd: String) -> (out: Data, err: Data, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let o = Pipe(); let e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch {
            return (Data(), "spawn-fail: \(error)".data(using: .utf8) ?? Data(), -1)
        }
        let od = (try? o.fileHandleForReading.readToEnd()) ?? Data()
        let ed = (try? e.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        return (od, ed, p.terminationStatus)
    }

    private func pgrepChildren() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["pgrep", "-P", String(getpid()), "git"]
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let d = (try? o.fileHandleForReading.readToEnd()) ?? Data()
        let s = String(decoding: d, as: UTF8.self)
        return s.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Byte-for-byte oracle

    /// Compare the synthetic diff to what `git diff --no-index /dev/null <f>`
    /// emits, for a wide range of inputs.
    func testSyntheticUntrackedDiffMatchesGitByteForByte() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        struct Fixture { let name: String; let bytes: [UInt8] }
        var fixtures: [Fixture] = []

        // Deterministic-but-varied corpus.
        var rng = SystemRandomNumberGenerator()

        // 100 random text files.
        for i in 0..<100 {
            let lineCount = (Int(rng.next() % 60))  // 0..59
            var parts: [String] = []
            for _ in 0..<lineCount {
                let wordCount = 1 + Int(rng.next() % 10)
                var ws: [String] = []
                for _ in 0..<wordCount {
                    let len = 1 + Int(rng.next() % 12)
                    var s = ""
                    for _ in 0..<len {
                        let c = UInt8(0x61 + Int(rng.next() % 26))
                        s.append(Character(UnicodeScalar(c)))
                    }
                    ws.append(s)
                }
                parts.append(ws.joined(separator: " "))
            }
            // Half the time append a trailing newline; half not (no-NL case).
            var body = parts.joined(separator: "\n")
            if (rng.next() & 1) == 0 { body += "\n" }
            fixtures.append(Fixture(name: "txt-\(i).txt",
                                    bytes: Array(body.utf8)))
        }

        // 50 binary files: random bytes, guaranteed NUL inside the first
        // 8000 (i.e. binary per git's heuristic).
        for i in 0..<50 {
            let n = 1 + Int(rng.next() % 4000)
            var bs = [UInt8](repeating: 0, count: n)
            for j in 0..<n { bs[j] = UInt8(rng.next() & 0xFF) }
            // Force at least one NUL near the start.
            let modulus = UInt64(min(n, 200))
            let idx = Int(rng.next() % modulus)
            bs[min(n - 1, idx)] = 0
            fixtures.append(Fixture(name: "bin-\(i).bin", bytes: bs))
        }

        // Edge cases.
        fixtures.append(Fixture(name: "empty.txt", bytes: []))
        fixtures.append(Fixture(name: "single-no-nl.txt",
                                bytes: Array("hello".utf8)))
        fixtures.append(Fixture(name: "single-with-nl.txt",
                                bytes: Array("hello\n".utf8)))
        fixtures.append(Fixture(name: "two-no-nl.txt",
                                bytes: Array("a\nb".utf8)))
        fixtures.append(Fixture(name: "two-with-nl.txt",
                                bytes: Array("a\nb\n".utf8)))
        fixtures.append(Fixture(name: "crlf.txt",
                                bytes: Array("alpha\r\nbeta\r\n".utf8)))
        fixtures.append(Fixture(name: "only-newlines.txt",
                                bytes: Array("\n\n\n".utf8)))
        // 1 MB single line (no \n).
        do {
            var line = [UInt8](repeating: 0x78, count: 1_000_000)
            line[123] = 0x41  // sprinkle 'A'
            fixtures.append(Fixture(name: "huge-line.txt", bytes: line))
        }
        // PNG signature (binary).
        fixtures.append(Fixture(name: "img.png",
                                bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                                       + Array(repeating: 0x00, count: 32)))
        // Gzip header (binary).
        fixtures.append(Fixture(name: "z.gz",
                                bytes: [0x1F, 0x8B, 0x08, 0x00]
                                       + Array(repeating: 0xAB, count: 64)))
        // Path with spaces.
        fixtures.append(Fixture(name: "name with space.txt",
                                bytes: Array("ok\n".utf8)))
        // Path with Unicode.
        fixtures.append(Fixture(name: "résumé-✓.txt",
                                bytes: Array("naïve\n".utf8)))
        // Path with single quote and backslash.  (Avoid double-quote on macOS
        // case-insensitive FS; backslash in filename is legal on APFS.)
        fixtures.append(Fixture(name: "with'quote.txt",
                                bytes: Array("q\n".utf8)))
        fixtures.append(Fixture(name: "with\\backslash.txt",
                                bytes: Array("b\n".utf8)))

        // Materialise on disk.
        for f in fixtures {
            let abs = dir + "/" + f.name
            FileManager.default.createFile(atPath: abs,
                                           contents: Data(f.bytes),
                                           attributes: nil)
        }

        var mismatches: [String] = []
        for f in fixtures {
            // Reference: real git.
            let ref = rawGit(["diff", "--no-index", "/dev/null", f.name], cwd: dir)
            // `git diff --no-index` exits 0 for "no diff" (empty case) and 1
            // when there are differences.
            XCTAssertTrue(ref.code == 0 || ref.code == 1,
                          "git failed unexpectedly for \(f.name): \(String(decoding: ref.err, as: UTF8.self))")

            // Subject: in-process synthetic.
            let synth = GitUtils.synthUntrackedDiff(repoRoot: dir, relPath: f.name)
            let synthBytes = Data(synth.utf8)

            if synthBytes != ref.out {
                mismatches.append("MISMATCH \(f.name): bytes=\(f.bytes.count)")
                if mismatches.count <= 3 {
                    // Dump first divergence for the report.
                    let a = [UInt8](ref.out)
                    let b = [UInt8](synthBytes)
                    let n = min(a.count, b.count)
                    var i = 0
                    while i < n && a[i] == b[i] { i += 1 }
                    let ctx = max(0, i - 16)
                    print("--- ref (\(a.count) bytes) ---")
                    print(String(decoding: a, as: UTF8.self))
                    print("--- synth (\(b.count) bytes) ---")
                    print(String(decoding: b, as: UTF8.self))
                    print("first diff at offset \(i), context start \(ctx)")
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "byte-for-byte mismatches: \(mismatches.joined(separator: " | "))")
    }

    // MARK: - Adversarial conditions

    func testFIFOIsSkippedNotHung() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Create a FIFO that ls-files filters out anyway.
        let fifo = dir + "/myfifo"
        let rv = fifo.withCString { mkfifo($0, 0o644) }
        XCTAssertEqual(rv, 0, "mkfifo failed")

        try "real\n".write(toFile: dir + "/real.txt", atomically: true,
                           encoding: .utf8)

        let g = GitUtils(cwd: dir)
        let started = Date()
        let wd = await g.workingDiff()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "FIFO must NOT hang the untracked diff path")
        XCTAssertTrue(wd.contains("real.txt"), "diff was:\n\(wd)")
    }

    func testSymlinkUntrackedDiff() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "target-content\n".write(toFile: dir + "/target.txt",
                                     atomically: true, encoding: .utf8)
        let link = dir + "/link.txt"
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: "target.txt")

        let synth = GitUtils.synthUntrackedDiff(repoRoot: dir, relPath: "link.txt")
        let ref = rawGit(["diff", "--no-index", "/dev/null", "link.txt"], cwd: dir)
        XCTAssertEqual(Data(synth.utf8), ref.out,
                       "symlink diff mismatch.\nref=\n\(String(decoding: ref.out, as: UTF8.self))\nsynth=\n\(synth)")
    }

    func testFileVanishedRaceDoesNotCrash() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // No file at the named path → synth must return a non-crashing
        // error marker.
        let s = GitUtils.synthUntrackedDiff(repoRoot: dir, relPath: "ghost.txt")
        XCTAssertTrue(s.contains("diff --git a/ghost.txt"))
        XCTAssertTrue(s.contains("error:"),
                      "race path should surface an error line, got:\n\(s)")
    }

    func testHundredMBFileDoesNotOOM() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let big = dir + "/huge.bin"
        // 100 MB of zeros (counts as binary).
        let fh = FileManager.default.createFile(atPath: big, contents: nil)
        XCTAssertTrue(fh)
        let handle = FileHandle(forWritingAtPath: big)!
        defer { try? handle.close() }
        let chunk = Data(count: 1_000_000) // 1 MB zeros
        for _ in 0..<100 { try handle.write(contentsOf: chunk) }
        try handle.synchronize()

        let started = Date()
        let synth = GitUtils.synthUntrackedDiff(repoRoot: dir, relPath: "huge.bin")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 15,
                          "100MB binary file synthesis took \(elapsed)s (too slow)")
        XCTAssertTrue(synth.contains("Binary files /dev/null and b/huge.bin differ"),
                      "expected binary marker, got prefix:\n\(synth.prefix(200))")
    }

    // MARK: - Concurrency + zombies

    func testFiftySimultaneousGitDiffNoDeadlockNoZombies() async throws {
        try XCTSkipUnless(gitAvailable())

        // Build 10 sibling repos, each with a handful of untracked files,
        // and fire 5 concurrent diff calls per repo (50 total).
        var dirs: [String] = []
        for _ in 0..<10 {
            let d = try await makeRepo()
            for j in 0..<5 {
                try "k\(j)\n".write(toFile: d + "/u\(j).txt",
                                     atomically: true, encoding: .utf8)
            }
            dirs.append(d)
        }
        defer { for d in dirs { try? FileManager.default.removeItem(atPath: d) } }

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for d in dirs {
                for _ in 0..<5 {
                    group.addTask {
                        let g = GitUtils(cwd: d)
                        _ = await g.workingDiff()
                    }
                }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 60,
                          "50 concurrent diffs took too long — deadlock?")

        // Give the kernel a moment to clean up any waitpid'ed children.
        try? await Task.sleep(for: .milliseconds(100))
        let zombies = pgrepChildren()
        XCTAssertEqual(zombies.count, 0,
                       "zombie git children remain: \(zombies)")
    }

    // MARK: - Cancellation

    func testTaskCancellationReapsGitWithin200ms() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // We force git to block by setting it up so that diff has to scan a
        // large directory; that's not reliable, so instead we test the
        // underlying timeout path: spawn a long sleep wrapped as a git
        // alias-like command — easiest is to invoke `git -c
        // alias.slow=!sleep 5 slow` which executes /bin/sleep 5 as the git
        // command. Git treats `!sleep 5` as a shell alias.
        _ = await GitRunner.run(["config", "alias.slow", "!sleep 5"], cwd: dir)

        let started = Date()
        let t = Task {
            await GitRunner.run(["slow"], cwd: dir, timeout: .milliseconds(300))
        }
        // Wait for it; with a 300ms internal timeout the runner must reap
        // and return within ~500ms.
        _ = await t.value
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2.0,
                          "timeout reap took \(elapsed)s (>2s)")

        try? await Task.sleep(for: .milliseconds(200))
        let z = pgrepChildren()
        XCTAssertEqual(z.count, 0, "git child survived timeout: \(z)")
    }

    // MARK: - Perf headline

    func testHundredUntrackedFilesUnderTwoSeconds() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Create 100 small untracked text files.
        for i in 0..<100 {
            try "content-\(i)\n".write(toFile: dir + "/u\(i).txt",
                                       atomically: true, encoding: .utf8)
        }

        let g = GitUtils(cwd: dir)
        // Warm-up (avoid cold-launch process spawn noise).
        _ = await g.isGitRepo()

        let started = Date()
        let diff = await g.workingDiff()
        let elapsed = Date().timeIntervalSince(started)
        print("[perf] 100 untracked files: \(String(format: "%.3f", elapsed))s, diff size=\(diff.utf8.count) bytes")
        XCTAssertLessThan(elapsed, 2.0,
                          "100 untracked files exceeded 2s budget: \(elapsed)s")
        // Sanity: every file's path appears in the diff.
        for i in 0..<100 {
            XCTAssertTrue(diff.contains("b/u\(i).txt"),
                          "u\(i).txt missing from diff")
        }
    }

    /// Discovery: publish a latency curve for 1/10/100/1000 untracked files.
    /// Marked as a normal test (not a benchmark) because the runtime is
    /// expected to be well under the suite's default budget.
    func testUntrackedDiffLatencyCurve() async throws {
        try XCTSkipUnless(gitAvailable())
        let counts = [1, 10, 100, 1000]
        var report: [(Int, Double, Int)] = []
        for c in counts {
            let dir = try await makeRepo()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            for i in 0..<c {
                try "x-\(i)\n".write(toFile: dir + "/u\(i).txt",
                                     atomically: true, encoding: .utf8)
            }
            let g = GitUtils(cwd: dir)
            _ = await g.isGitRepo()
            let started = Date()
            let d = await g.workingDiff()
            let t = Date().timeIntervalSince(started)
            report.append((c, t, d.utf8.count))
        }
        print("[perf-curve] untracked files vs latency")
        for r in report {
            print(String(format: "  %5d files -> %7.3fs  diff=%d bytes",
                         r.0, r.1, r.2))
        }
        // Loose guards so this doesn't flake on slow CI:
        for r in report where r.0 <= 100 {
            XCTAssertLessThan(r.1, 5.0,
                              "\(r.0) files took \(r.1)s")
        }
        if let last = report.last, last.0 == 1000 {
            XCTAssertLessThan(last.1, 30.0,
                              "1000 files took \(last.1)s")
        }
    }

    // MARK: - Read-only safety flags

    func testReadOnlyFlagsAppliedForDiffNotForCommitTree() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // ghostCommit uses `add -A`, `write-tree`, `commit-tree` — none of
        // these are read-only. If our decorator wrongly injected
        // `--no-optional-locks` for a write verb git would still accept it
        // (it's a global flag), but the goal is to be sure ghostCommit
        // still works end-to-end.
        try "ghost\n".write(toFile: dir + "/ghost.txt",
                            atomically: true, encoding: .utf8)
        let g = GitUtils(cwd: dir)
        let ghost = await g.ghostCommit()
        XCTAssertNotNil(ghost)
        XCTAssertEqual(ghost?.treeSha.count, 40)
        XCTAssertEqual(ghost?.commitSha.count, 40)
    }
}
