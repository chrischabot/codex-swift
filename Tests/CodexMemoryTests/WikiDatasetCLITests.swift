import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for the wiki-dataset CLI: pure parse/format/build helpers, the bounded
/// DatasetProfiler (exact count only within the read cap; capped sample), and the
/// runProfile integration (remote → planned-steps note + NO fetch; local → profile +
/// capped sample notes + manifest size refresh).
final class WikiDatasetCLITests: XCTestCase {
    private typealias DS = CodexMemoryWikiDataset

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "wds-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private func tempFile(_ content: String) throws -> String {
        let p = NSTemporaryDirectory() + "wdsfile-\(UUID().uuidString).csv"
        try content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testParseAddValidatesAndBuilds() throws {
        let o = try DS.parseAdd(["--id", "imagenet", "--title", "ImageNet", "--status", "external",
                                 "--storage", "remote", "--locations", "s3://x", "--license", "research"])
        XCTAssertEqual(o.datasetID, "imagenet"); XCTAssertEqual(o.storage, "remote")
        let m = DS.manifest(from: o, now: 200, createdAt: 100)
        XCTAssertEqual(m.createdAt, 100); XCTAssertEqual(m.updatedAt, 200)
        XCTAssertEqual(m.locations, "s3://x"); XCTAssertEqual(m.license, "research")
        XCTAssertThrowsError(try DS.parseAdd(["--id", "x", "--title", "T", "--storage", "bogus"]))
        XCTAssertThrowsError(try DS.parseAdd(["--id", "x", "--title", "T", "--status", "weird"]))
        XCTAssertThrowsError(try DS.parseAdd(["--title", "T"]))   // missing id
    }

    func testParseNoteValidatesKind() throws {
        let n = try DS.parseNote(["ds1", "--kind", "sample", "--title", "T", "--body", "B"])
        XCTAssertEqual(n.id, "ds1"); XCTAssertEqual(n.kind, "sample")
        XCTAssertThrowsError(try DS.parseNote(["ds1", "--kind", "bogus", "--title", "T", "--body", "B"]))
        XCTAssertThrowsError(try DS.parseNote(["--kind", "sample", "--title", "T", "--body", "B"]))   // missing id
    }

    func testProfilerExactCountWithinCapAndCappedSample() throws {
        let content = (1...50).map { "row\($0),value\($0)" }.joined(separator: "\n") + "\n"
        let path = try tempFile(content)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let p = try XCTUnwrap(DatasetProfiler.profileLocalFile(path: path, rowCap: 20, byteCap: 1 << 20))
        XCTAssertFalse(p.truncated)
        XCTAssertEqual(p.lineCount, 50, "whole file fit → exact count (trailing newline not counted)")
        XCTAssertEqual(p.sample.count, 20, "sample capped at rowCap")
        XCTAssertEqual(p.sample.first, "row1,value1")
        XCTAssertGreaterThan(p.sizeBytes, 0)
    }

    func testProfilerTruncatedFileReportsUnknownCount() throws {
        let content = String(repeating: "abcdefghij\n", count: 1000)   // ~11KB
        let path = try tempFile(content)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let p = try XCTUnwrap(DatasetProfiler.profileLocalFile(path: path, rowCap: 5, byteCap: 64))   // tiny cap
        XCTAssertTrue(p.truncated, "file exceeds the read cap")
        XCTAssertEqual(p.lineCount, -1, "unknown count when truncated")
        XCTAssertLessThanOrEqual(p.sample.count, 5)
    }

    func testProfilerRejectsMissingAndDirectory() throws {
        XCTAssertNil(DatasetProfiler.profileLocalFile(path: NSTemporaryDirectory() + "nope-\(UUID()).x"))
        XCTAssertNil(DatasetProfiler.profileLocalFile(path: NSTemporaryDirectory()), "a directory is not a profileable file")
    }

    func testRunProfileLocalAddsNotesAndUpdatesManifest() async throws {
        let store = try makeStore()
        let now: Int64 = 1000
        _ = try await store.upsertDatasetManifest(DatasetManifestRow(
            datasetID: "local1", title: "Local", status: "active", storage: "local", createdAt: now, updatedAt: now))
        let path = try tempFile("a,b\n1,2\n3,4\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (out, ok) = try await DS.runProfile(["local1", "--path", path], store: store, now: now + 1)
        XCTAssertTrue(ok); XCTAssertTrue(out.contains("profiled local1"))
        let m = try await store.datasetManifest(datasetID: "local1")
        XCTAssertEqual(m?.recordCount, 3, "3 data lines counted")
        XCTAssertNotNil(m?.sizeBytes)
        let notes = try await store.datasetNotes(manifestID: m!.id)
        XCTAssertEqual(Set(notes.map(\.noteKind)), ["profile", "sample"])
        XCTAssertTrue(notes.contains { $0.bodyMd.contains("may contain sensitive data") }, "sample carries a sensitivity warning")
    }

    func testRunProfileRemoteFetchesNothing() async throws {
        let store = try makeStore()
        let now: Int64 = 1000
        _ = try await store.upsertDatasetManifest(DatasetManifestRow(
            datasetID: "remote1", title: "Remote", status: "external", storage: "remote", createdAt: now, updatedAt: now))
        // even with a --path, a remote dataset must NOT read it.
        let (out, ok) = try await DS.runProfile(["remote1", "--path", "/etc/hosts"], store: store, now: now + 1)
        XCTAssertTrue(ok); XCTAssertTrue(out.contains("fetched nothing"))
        let m = try await store.datasetManifest(datasetID: "remote1")
        let notes = try await store.datasetNotes(manifestID: m!.id)
        XCTAssertEqual(notes.map(\.noteKind), ["query"], "only a planned-steps note; no profile/sample of the local path")
        XCTAssertNil(m?.sizeBytes, "remote manifest size not touched")
    }

    func testRunProfileRowsCappedAt20() async throws {
        let store = try makeStore()
        let now: Int64 = 1000
        _ = try await store.upsertDatasetManifest(DatasetManifestRow(
            datasetID: "big", title: "Big", status: "active", storage: "local", createdAt: now, updatedAt: now))
        let path = try tempFile((1...100).map { "r\($0)" }.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        // ask for 1000 rows → hard-capped at 20.
        let (_, ok) = try await DS.runProfile(["big", "--path", path, "--rows", "1000"], store: store, now: now + 1)
        XCTAssertTrue(ok)
        let m = try await store.datasetManifest(datasetID: "big")
        let sample = try await store.datasetNotes(manifestID: m!.id).first { $0.noteKind == "sample" }
        let rowLines = (sample?.bodyMd ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("r") }
        XCTAssertLessThanOrEqual(rowLines.count, 20, "sample hard-capped at 20 rows regardless of --rows")
    }

    func testProfilerNewlineEdgeCases() throws {
        func prof(_ s: String, rows: Int = 20) throws -> DatasetProfile {
            let p = try tempFile(s); defer { try? FileManager.default.removeItem(atPath: p) }
            return try XCTUnwrap(DatasetProfiler.profileLocalFile(path: p, rowCap: rows, byteCap: 1 << 20))
        }
        // CRLF (Windows CSV) — must count 2, not 1.
        let crlf = try prof("row1\r\nrow2\r\n")
        XCTAssertEqual(crlf.lineCount, 2, "CRLF lines counted correctly")
        XCTAssertEqual(crlf.sample, ["row1", "row2"], "CRLF split into rows, no trailing empty")
        // empty file → 0 records.
        XCTAssertEqual(try prof("").lineCount, 0)
        XCTAssertEqual(try prof("").sample, [])
        // no trailing newline.
        XCTAssertEqual(try prof("a\nb").lineCount, 2)
        // trailing newline → no spurious empty sample row.
        XCTAssertEqual(try prof("a\nb\n").sample, ["a", "b"])
        // blank lines are real lines.
        XCTAssertEqual(try prof("\n\n\n").lineCount, 3)
    }

    func testProfilerHardCapsSampleRegardlessOfRowCap() throws {
        let path = try tempFile((1...100).map { "r\($0)" }.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        // ask the profiler DIRECTLY for 1000 rows → still capped at the hard ceiling (20).
        let p = try XCTUnwrap(DatasetProfiler.profileLocalFile(path: path, rowCap: 1000, byteCap: 1 << 20))
        XCTAssertEqual(p.sample.count, DatasetProfiler.hardSampleCap)
        XCTAssertEqual(p.lineCount, 100, "count is still exact even though the sample is capped")
    }

    func testProfilerByteCapBoundaryIsNotTruncated() throws {
        let content = "abcd\nefgh\n"   // 10 bytes
        let path = try tempFile(content)
        defer { try? FileManager.default.removeItem(atPath: path) }
        // byteCap exactly equal to the file size → whole file read → NOT truncated.
        let exact = try XCTUnwrap(DatasetProfiler.profileLocalFile(path: path, byteCap: content.utf8.count))
        XCTAssertFalse(exact.truncated); XCTAssertEqual(exact.lineCount, 2)
        // one byte short → truncated → unknown count.
        let short = try XCTUnwrap(DatasetProfiler.profileLocalFile(path: path, byteCap: content.utf8.count - 1))
        XCTAssertTrue(short.truncated); XCTAssertEqual(short.lineCount, -1)
    }

    func testRunProfileMissingManifestReturnsNotOk() async throws {
        let store = try makeStore()
        let (out, ok) = try await DS.runProfile(["ghost", "--path", "/tmp/x"], store: store, now: 1)
        XCTAssertFalse(ok); XCTAssertTrue(out.contains("no manifest"))
    }

    func testRunProfilePreservesManifestCreatedAt() async throws {
        let store = try makeStore()
        _ = try await store.upsertDatasetManifest(DatasetManifestRow(
            datasetID: "d", title: "D", status: "active", storage: "local", createdAt: 500, updatedAt: 500))
        let path = try tempFile("x\ny\n"); defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await DS.runProfile(["d", "--path", path], store: store, now: 900)
        let m = try await store.datasetManifest(datasetID: "d")
        XCTAssertEqual(m?.createdAt, 500, "profile's manifest upsert preserves createdAt")
        XCTAssertEqual(m?.updatedAt, 900)
    }

    func testFormatListAndShow() throws {
        let m = [DatasetManifestRow(datasetID: "d1", title: "D1", status: "active", storage: "local",
                                    sizeBytes: 99, recordCount: 3, createdAt: 1, updatedAt: 1)]
        let json = DS.formatList(m, json: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["count"] as? Int, 1)
        XCTAssertEqual((obj["datasets"] as? [[String: Any]])?.first?["sizeBytes"] as? Int, 99)
        let show = DS.formatShow(m[0], notes: [DatasetNoteRow(manifestID: 1, noteKind: "profile", title: "p", bodyMd: "b", createdAt: 1)], json: false)
        XCTAssertTrue(show.contains("records: 3"))
        XCTAssertTrue(show.contains("[profile] p"))
    }
}
