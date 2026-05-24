import XCTest
import Foundation
@testable import Connectors

final class ConnectorsTests: XCTestCase {

    private func tmpHome() -> String {
        let p = NSTemporaryDirectory() + "conn-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testDiscoversAndSorts() {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let json = """
        { "connectors": [
          { "id": "z", "name": "Zed", "description": "z conn" },
          { "id": "a", "name": "Alpha", "description": "a conn" }
        ] }
        """
        try? json.write(toFile: home + "/connectors.json", atomically: true, encoding: .utf8)
        let recs = ConnectorsDiscovery().discover(codexHome: home)
        XCTAssertEqual(recs.map { $0.id }, ["a", "z"], "sorted by id")
        XCTAssertEqual(recs[0].name, "Alpha")
    }

    func testMissingOrMalformedIsEmpty() {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertTrue(ConnectorsDiscovery().discover(codexHome: home).isEmpty)
        try? "not json".write(toFile: home + "/connectors.json",
                              atomically: true, encoding: .utf8)
        XCTAssertTrue(ConnectorsDiscovery().discover(codexHome: home).isEmpty)
    }
}