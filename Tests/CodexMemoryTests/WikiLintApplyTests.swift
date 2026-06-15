import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for `wiki-lint --apply` (§5.D auto-fix lane) + the removed stale
/// `claim_schema_missing` stub. Properties:
/// 1. --apply regenerates a stale agent-digest's store-derived counts; re-lint is clean (idempotent).
/// 2. --apply creates a missing digest.
/// 3. WITHOUT --apply the digest is never touched and the issue stays.
/// 4. --apply with no vault path is a safe no-op.
/// 5. The obsolete `claim_schema_missing` info stub is gone (claims are durable since M0).
final class WikiLintApplyTests: XCTestCase {

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "lintapply-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }

    /// A store with `n` ordinary (non-compiled) documents → health.documentCount == n.
    private func seed(_ store: MemoryStore, docs n: Int) async throws {
        for i in 0..<n {
            _ = try await store.upsertDocument(DocumentRow(
                source: .web, sourceURI: "https://ex.com/\(i)", bodyPath: "inline:\(i)",
                fetchedAt: 1, contentSHA: Data("\(i)".utf8), rawBytes: 1))
        }
    }

    private func tempDir(_ tag: String) throws -> String {
        let d = NSTemporaryDirectory() + "\(tag)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    private func writeDigest(_ vault: String, json: String) throws {
        let dir = vault + "/_digests"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: URL(fileURLWithPath: dir + "/agent-digest.json"))
    }

    func testApplyRegeneratesStaleDigestIdempotently() async throws {
        let store = try makeStore()
        try await seed(store, docs: 3)
        let vault = try tempDir("vault"); let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: vault); try? FileManager.default.removeItem(atPath: root) }
        try writeDigest(vault, json: #"{"version":1,"documents":999,"chunks":999,"source_pages":[]}"#)

        var opts = WikiLintOptions(); opts.vaultPath = vault

        // 1. detect the drift
        let before = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(before.issues.contains { $0.code == "stale_digest" }, "stale counts are flagged")
        XCTAssertTrue(before.appliedFixes.isEmpty)

        // 2. --apply repairs it
        opts.apply = true
        let applied = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertFalse(applied.issues.contains { $0.code == "stale_digest" }, "fixed → removed from issues")
        XCTAssertEqual(applied.appliedFixes.count, 1)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: vault + "/_digests/agent-digest.json"))) as? [String: Any])
        XCTAssertEqual(obj["documents"] as? Int, 3, "counts re-derived from the store")
        XCTAssertEqual(obj["chunks"] as? Int, 0)
        XCTAssertNotNil(obj["source_pages"], "existing fields preserved")

        // 3. idempotent: a fresh lint sees no drift
        opts.apply = false
        let after = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertFalse(after.issues.contains { $0.code == "stale_digest" })
    }

    func testApplyCreatesMissingDigest() async throws {
        let store = try makeStore()
        try await seed(store, docs: 2)
        let vault = try tempDir("vault"); let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: vault); try? FileManager.default.removeItem(atPath: root) }
        // no digest file at all
        var opts = WikiLintOptions(); opts.vaultPath = vault

        let before = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(before.issues.contains { $0.code == "missing_digest" })

        opts.apply = true
        let applied = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertFalse(applied.issues.contains { $0.code == "missing_digest" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/_digests/agent-digest.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: vault + "/_digests/agent-digest.json"))) as? [String: Any])
        XCTAssertEqual(obj["documents"] as? Int, 2)
    }

    func testNoApplyLeavesDigestUntouched() async throws {
        let store = try makeStore()
        try await seed(store, docs: 3)
        let vault = try tempDir("vault"); let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: vault); try? FileManager.default.removeItem(atPath: root) }
        let stale = #"{"version":1,"documents":999,"chunks":999,"source_pages":[]}"#
        try writeDigest(vault, json: stale)

        var opts = WikiLintOptions(); opts.vaultPath = vault   // apply defaults to false
        let report = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(report.issues.contains { $0.code == "stale_digest" }, "without --apply the issue remains")
        XCTAssertTrue(report.appliedFixes.isEmpty)
        let raw = try String(contentsOfFile: vault + "/_digests/agent-digest.json", encoding: .utf8)
        XCTAssertTrue(raw.contains("999"), "digest file is NOT modified without --apply")
    }

    func testApplyWithoutVaultIsNoOp() async throws {
        let store = try makeStore()
        try await seed(store, docs: 1)
        let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        var opts = WikiLintOptions(); opts.apply = true   // no vaultPath
        let report = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(report.appliedFixes.isEmpty, "no vault → nothing to fix, no crash")
    }

    func testClaimSchemaStubRemoved() async throws {
        let store = try makeStore()
        try await seed(store, docs: 1)
        let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let opts = WikiLintOptions()
        let report = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertFalse(report.issues.contains { $0.code == "claim_schema_missing" },
                       "the obsolete claim-schema-missing stub is gone (claims are durable)")
    }

    func testApplyRefusesSymlinkedDigestAndStaysOutsideVault() async throws {
        let store = try makeStore()
        try await seed(store, docs: 3)
        let vault = try tempDir("vault"); let root = try tempDir("root"); let outside = try tempDir("outside")
        defer { for d in [vault, root, outside] { try? FileManager.default.removeItem(atPath: d) } }
        // An external file the digest path symlinks to, holding stale counts.
        let victim = outside + "/victim.json"
        try Data(#"{"version":1,"documents":999,"chunks":999}"#.utf8).write(to: URL(fileURLWithPath: victim))
        try FileManager.default.createDirectory(atPath: vault + "/_digests", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: vault + "/_digests/agent-digest.json", withDestinationPath: victim)

        var opts = WikiLintOptions(); opts.vaultPath = vault; opts.apply = true
        let report = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(report.appliedFixes.contains { $0.hasPrefix("FAILED") }, "writing a symlinked digest is refused")
        XCTAssertTrue(report.issues.contains { $0.code == "stale_digest" }, "the issue is NOT falsely cleared on a failed write")
        let victimRaw = try String(contentsOfFile: victim, encoding: .utf8)
        XCTAssertTrue(victimRaw.contains("999"), "the external symlink target is NEVER overwritten")
    }

    func testApplyIsNoOpWhenDigestIsCurrent() async throws {
        let store = try makeStore()
        try await seed(store, docs: 2)
        let vault = try tempDir("vault"); let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: vault); try? FileManager.default.removeItem(atPath: root) }
        // already-correct counts (documents=2, chunks=0)
        try writeDigest(vault, json: #"{"version":1,"documents":2,"chunks":0,"source_pages":[]}"#)
        var opts = WikiLintOptions(); opts.vaultPath = vault; opts.apply = true
        let report = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(report.appliedFixes.isEmpty, "--apply does nothing when there's no digest drift")
        XCTAssertFalse(report.issues.contains { $0.code == "stale_digest" })
    }

    func testTwoConsecutiveAppliesSecondIsNoOp() async throws {
        let store = try makeStore()
        try await seed(store, docs: 4)
        let vault = try tempDir("vault"); let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: vault); try? FileManager.default.removeItem(atPath: root) }
        try writeDigest(vault, json: #"{"version":1,"documents":1,"chunks":7,"source_pages":[]}"#)
        var opts = WikiLintOptions(); opts.vaultPath = vault; opts.apply = true
        let first = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertEqual(first.appliedFixes.count, 1, "first apply repairs")
        let second = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(second.appliedFixes.isEmpty, "second apply is a true no-op (idempotent)")
    }

    func testApplyFixesDigestStaleOnlyOnChunks() async throws {
        let store = try makeStore()
        try await seed(store, docs: 2)
        let vault = try tempDir("vault"); let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: vault); try? FileManager.default.removeItem(atPath: root) }
        // documents correct (2) but chunks wrong (5 vs store 0)
        try writeDigest(vault, json: #"{"version":1,"documents":2,"chunks":5,"source_pages":[]}"#)
        var opts = WikiLintOptions(); opts.vaultPath = vault
        let before = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertTrue(before.issues.contains { $0.code == "stale_digest" }, "chunk-only drift is still flagged")
        opts.apply = true
        let applied = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertFalse(applied.issues.contains { $0.code == "stale_digest" })
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: vault + "/_digests/agent-digest.json"))) as? [String: Any])
        XCTAssertEqual(obj["chunks"] as? Int, 0)
    }

    func testNonObjectDigestTreatedAsMissing() async throws {
        let store = try makeStore()
        try await seed(store, docs: 2)
        let vault = try tempDir("vault"); let root = try tempDir("root")
        defer { try? FileManager.default.removeItem(atPath: vault); try? FileManager.default.removeItem(atPath: root) }
        try writeDigest(vault, json: #"[1,2,3]"#)   // valid JSON, but an array, not an object
        var opts = WikiLintOptions(); opts.vaultPath = vault; opts.apply = true
        let report = try await CodexMemoryWikiLint.lint(roots: [root], store: store, options: opts)
        XCTAssertFalse(report.issues.contains { $0.code == "missing_digest" })
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: vault + "/_digests/agent-digest.json"))) as? [String: Any])
        XCTAssertEqual(obj["documents"] as? Int, 2, "a non-object digest is replaced with a valid minimal one")
    }
}
