import XCTest
import Foundation
@testable import Config

private func tomlTmp() -> String {
    let p = NSTemporaryDirectory() + "toml-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

final class TOMLTests: XCTestCase {

    func testParsesScalarsTablesArraysInline() throws {
        let text = """
        # comment
        model = "gpt-5.1-codex"
        retries = 1_000
        ratio = 3.14
        big = 0xFF
        flag = true
        when = 1979-05-27T07:32:00Z
        list = [1, 2, 3,]
        mixed = [ "a", { k = 1 }, [true, false] ]

        [server]
        host = "localhost"
        port = 8080

        [server.tls]
        enabled = true

        [[items]]
        name = "one"

        [[items]]
        name = "two"
        """
        let r = try TOML.parse(text)
        XCTAssertEqual(r["model"]?.stringValue, "gpt-5.1-codex")
        XCTAssertEqual(r["retries"]?.intValue, 1000)
        if case .double(let d)? = r["ratio"] { XCTAssertEqual(d, 3.14, accuracy: 1e-9) }
        else { XCTFail("ratio not double") }
        XCTAssertEqual(r["big"]?.intValue, 255)
        XCTAssertEqual(r["flag"]?.boolValue, true)
        XCTAssertEqual(r["when"]?.stringValue, "1979-05-27T07:32:00Z")
        if case .array(let a)? = r["list"] { XCTAssertEqual(a.count, 3) }
        else { XCTFail("list not array") }
        XCTAssertEqual(r["server"]?.objectValue?["port"]?.intValue, 8080)
        XCTAssertEqual(r["server"]?.objectValue?["tls"]?
            .objectValue?["enabled"]?.boolValue, true)
        if case .array(let items)? = r["items"] {
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].objectValue?["name"]?.stringValue, "one")
            XCTAssertEqual(items[1].objectValue?["name"]?.stringValue, "two")
        } else { XCTFail("items not array-of-tables") }
    }

    func testDottedKeysAndStrings() throws {
        let text = #"""
        a.b.c = "x"
        s = "line\nbreak\tend"
        lit = 'C:\path\no\escape'
        ml = """
        hello
        world"""
        mll = '''raw
        text'''
        """#
        let r = try TOML.parse(text)
        XCTAssertEqual(r["a"]?.objectValue?["b"]?
            .objectValue?["c"]?.stringValue, "x")
        XCTAssertEqual(r["s"]?.stringValue, "line\nbreak\tend")
        XCTAssertEqual(r["lit"]?.stringValue, #"C:\path\no\escape"#)
        XCTAssertEqual(r["ml"]?.stringValue, "hello\nworld")
        XCTAssertEqual(r["mll"]?.stringValue, "raw\ntext")
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try TOML.parse("a = "))
        XCTAssertThrowsError(try TOML.parse("a = \"unterminated"))
        XCTAssertThrowsError(try TOML.parse("x = 1\nx = 2"))
        XCTAssertThrowsError(try TOML.parse("[t]\n[t]\n"))
        XCTAssertThrowsError(try TOML.parse("a = 999999999999999999999999999999"))
    }

    func testProfileDeepMergeAndResolutionOrder() {
        let home = tomlTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        profile = "dev"
        model = "base-model"

        [server]
        host = "base-host"
        port = 1

        [profiles.dev.server]
        port = 9000

        [profiles.prod]
        model = "prod-model"
        """
        try? toml.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let loader = ConfigLoader(codexHome: home)

        // Root `profile = "dev"` selected.
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.profileName, "dev")
        XCTAssertEqual(cfg.string("server.host"), "base-host")
        XCTAssertEqual(cfg.int("server.port"), 9000, "profile overlay wins")
        XCTAssertNil(cfg.value("profiles"), "raw profiles map not surfaced")
        XCTAssertEqual(cfg.origins["server"], "toml")

        // env CODEX_CFG_PROFILE beats root profile.
        let cfg2 = loader.load(env: ["CODEX_CFG_PROFILE": "prod"])
        XCTAssertEqual(cfg2.profileName, "prod")
        XCTAssertEqual(cfg2.string("model"), "prod-model")

        // explicit override beats env + root.
        let cfg3 = loader.load(env: ["CODEX_CFG_PROFILE": "prod"],
                               overrides: ["profile": .string("dev")])
        XCTAssertEqual(cfg3.profileName, "dev")
        XCTAssertEqual(cfg3.int("server.port"), 9000)
    }

    func testMemoriesKeyAliasNormalization() {
        let home = tomlTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        [memories]
        no_memories_if_mcp_or_web_search = true
        """
        try? toml.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let cfg = ConfigLoader(codexHome: home).load(env: [:])
        XCTAssertEqual(cfg.bool("memories.disable_on_external_context"), true)
        XCTAssertNil(cfg.value("memories.no_memories_if_mcp_or_web_search"))
    }

    func testEnvBeatsTomlLayer() {
        let home = tomlTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try? #"model = "toml-model""#
            .write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let loader = ConfigLoader(codexHome: home)

        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "toml-model")
        XCTAssertEqual(cfg.origins["model"], "toml")

        let cfg2 = loader.load(env: ["CODEX_CFG_MODEL": "env-model"])
        XCTAssertEqual(cfg2.model, "env-model", "env beats toml")
        XCTAssertEqual(cfg2.origins["model"], "env")
    }

    func testSerializeRoundTrip() throws {
        let root: [String: ConfigValue] = [
            "model": .string("gpt"),
            "n": .int(7),
            "x": .double(1.5),
            "ok": .bool(true),
            "list": .array([.int(1), .int(2)]),
            "server": .object([
                "host": .string("h"),
                "tls": .object(["enabled": .bool(false)]),
            ]),
            "items": .array([
                .object(["name": .string("a")]),
                .object(["name": .string("b")]),
            ]),
        ]
        let txt = TOML.serialize(root)
        let back = try TOML.parse(txt)
        XCTAssertEqual(back["model"]?.stringValue, "gpt")
        XCTAssertEqual(back["n"]?.intValue, 7)
        if case .double(let d)? = back["x"] { XCTAssertEqual(d, 1.5, accuracy: 1e-9) }
        else { XCTFail("x not double") }
        XCTAssertEqual(back["ok"]?.boolValue, true)
        XCTAssertEqual(back["server"]?.objectValue?["host"]?.stringValue, "h")
        XCTAssertEqual(back["server"]?.objectValue?["tls"]?
            .objectValue?["enabled"]?.boolValue, false)
        if case .array(let items)? = back["items"] {
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[1].objectValue?["name"]?.stringValue, "b")
        } else { XCTFail("items not array-of-tables") }

        // Deterministic: identical input → identical output.
        XCTAssertEqual(TOML.serialize(root), TOML.serialize(root))
    }

    func testPersistTOMLRoundTrip() throws {
        let home = tomlTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let loader = ConfigLoader(codexHome: home)
        try loader.persistTOML(["model": .string("written"),
                                "nested": .object(["k": .int(3)])])
        let cfg = loader.load(env: [:])
        XCTAssertEqual(cfg.model, "written")
        XCTAssertEqual(cfg.int("nested.k"), 3)
    }
}