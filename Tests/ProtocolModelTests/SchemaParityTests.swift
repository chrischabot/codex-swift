import XCTest
import Foundation
@testable import ProtocolModel

/// Verifies the implemented method surface (`Method.all`) against the
/// authoritative pinned `codex` app-server JSON schema. The schema dir is
/// resolved from `$CODEX_SCHEMA_DIR`, then a sibling `~/codex/...`, then a
/// `../codex/...` path relative to the package; the test skips cleanly when
/// none is present so CI without the codex tree stays green (same policy as
/// the live tests).
final class SchemaParityTests: XCTestCase {

    private func schemaDir() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["CODEX_SCHEMA_DIR"],
           !env.isEmpty { candidates.append(env) }
        candidates.append(NSHomeDirectory()
            + "/codex/codex-rs/app-server-protocol/schema/json")
        let cwd = fm.currentDirectoryPath
        candidates.append(cwd + "/../codex/codex-rs/app-server-protocol/schema/json")
        candidates.append((cwd as NSString).deletingLastPathComponent
            + "/codex/codex-rs/app-server-protocol/schema/json")
        var isDir: ObjCBool = false
        for c in candidates where fm.fileExists(atPath: c, isDirectory: &isDir)
            && isDir.boolValue {
            if fm.fileExists(atPath: c + "/ClientRequest.json") { return c }
        }
        return nil
    }

    /// Recursively collect every `properties.method.const|enum` value.
    private func methods(in any: Any) -> Set<String> {
        var out: Set<String> = []
        func walk(_ o: Any) {
            if let dict = o as? [String: Any] {
                if let props = dict["properties"] as? [String: Any],
                   let m = props["method"] as? [String: Any] {
                    if let c = m["const"] as? String { out.insert(c) }
                    if let e = m["enum"] as? [Any] {
                        for v in e { if let s = v as? String { out.insert(s) } }
                    }
                }
                for v in dict.values { walk(v) }
            } else if let arr = o as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(any)
        return out
    }

    func testMethodSurfaceCoversPinnedCodexSchema() throws {
        guard let dir = schemaDir() else {
            throw XCTSkip("codex schema dir not found (set CODEX_SCHEMA_DIR)")
        }
        let url = URL(fileURLWithPath: dir + "/ClientRequest.json")
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        let codexMethods = methods(in: root)
        XCTAssertGreaterThanOrEqual(codexMethods.count, 50,
            "ClientRequest.json should expose the full client surface")

        let missing = codexMethods.subtracting(Method.all).sorted()
        XCTAssertTrue(missing.isEmpty,
            "Method.all is missing pinned Codex client methods: \(missing)")

        // Informational: methods we list that the pinned schema does not
        // (deprecated v1 aliases live outside ClientRequest.json — expected).
        let extras = Method.all.subtracting(codexMethods).sorted()
        if !extras.isEmpty {
            print("[schema-parity] extra (non-ClientRequest) methods: \(extras)")
        }
    }

    func testEveryPinnedMethodIsKnown() throws {
        guard let dir = schemaDir() else {
            throw XCTSkip("codex schema dir not found (set CODEX_SCHEMA_DIR)")
        }
        let data = try Data(contentsOf:
            URL(fileURLWithPath: dir + "/ClientRequest.json"))
        let root = try JSONSerialization.jsonObject(with: data)
        for m in methods(in: root).sorted() {
            XCTAssertTrue(Method.isKnown(m),
                "pinned Codex method '\(m)' must be a known method")
        }
    }

    func testEveryGenericPinnedMethodHasExplicitDefaultResponsePolicy() throws {
        guard let dir = schemaDir() else {
            throw XCTSkip("codex schema dir not found (set CODEX_SCHEMA_DIR)")
        }
        let data = try Data(contentsOf:
            URL(fileURLWithPath: dir + "/ClientRequest.json"))
        let root = try JSONSerialization.jsonObject(with: data)
        let pinned = methods(in: root)
        let generic = pinned.subtracting(ClientRequest.typedMethods)
        let missing = generic
            .filter { !GenericResponses.hasExplicitDefault(for: $0) }
            .sorted()
        XCTAssertTrue(missing.isEmpty,
            "Generic Codex methods need explicit default response policy: \(missing)")
    }
}
