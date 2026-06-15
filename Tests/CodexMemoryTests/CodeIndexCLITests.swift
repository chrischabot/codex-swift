import XCTest
import Foundation
@testable import codex_memory

/// Coverage for the code-index CLI's parsing + file walking (gbrain.md Wave 5.30).
/// The indexing itself is covered by CodeIndexer tests in MemoryProcessTests.
final class CodeIndexCLITests: XCTestCase {
    func testParseDefaults() throws {
        let o = try CodexMemoryCodeIndex.parse(["/some/path"])
        XCTAssertEqual(o.root, "/some/path")
        XCTAssertEqual(o.extensions, [".swift"])
        XCTAssertFalse(o.json)
    }

    func testParseExtAndJson() throws {
        let o = try CodexMemoryCodeIndex.parse(["/p", "--ext", "swift,ts,py", "--json"])
        XCTAssertEqual(o.extensions, [".swift", ".ts", ".py"], "ext list normalized with leading dots")
        XCTAssertTrue(o.json)
    }

    func testParseUnknownFlagThrows() {
        XCTAssertThrowsError(try CodexMemoryCodeIndex.parse(["--nope"]))
    }

    func testSourceFilesSkipsBuildAndFiltersExtension() throws {
        let root = NSTemporaryDirectory() + "code-walk-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.build/x", withIntermediateDirectories: true)
        try "struct A {}".write(toFile: root + "/Sources/A.swift", atomically: true, encoding: .utf8)
        try "notes".write(toFile: root + "/Sources/notes.txt", atomically: true, encoding: .utf8)
        try "struct B {}".write(toFile: root + "/.build/x/B.swift", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: root) }

        let files = CodexMemoryCodeIndex.sourceFiles(root: root, extensions: [".swift"])
        XCTAssertTrue(files.contains { $0.hasSuffix("Sources/A.swift") })
        XCTAssertFalse(files.contains { $0.contains("/.build/") }, ".build is excluded")
        XCTAssertFalse(files.contains { $0.hasSuffix(".txt") }, "non-matching extension excluded")
    }

    func testSourceFilesOnSingleFile() throws {
        let root = NSTemporaryDirectory() + "code-single-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let f = root + "/One.swift"
        try "enum One {}".write(toFile: f, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: root) }
        XCTAssertEqual(CodexMemoryCodeIndex.sourceFiles(root: f, extensions: [".swift"]), [f])
    }
}
