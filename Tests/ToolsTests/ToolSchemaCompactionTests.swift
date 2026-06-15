import XCTest
import Foundation
@testable import Tools
@testable import InfraPrimitives

/// Tests for the P2 tool-input-schema fidelity port (compaction + prune; the
/// pass-through architecture preserves oneOf/allOf/$ref/$defs verbatim).
final class ToolSchemaCompactionTests: XCTestCase {

    private func obj(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!,
            options: [.fragmentsAllowed]) as! [String: Any]
    }
    private func normLen(_ s: String) -> Int {
        ToolSchemaCompaction.normalizedLen(obj(s))
    }

    // MARK: pass-through fidelity (2.1 / 2.2 / 2.4)

    func testSmallSchemaWithCompositionsPassesThroughVerbatim() {
        // oneOf/allOf/anyOf in a small schema: fast path returns the string
        // unchanged (no $defs, under budget) — verbatim fidelity.
        let s = #"{"type":"object","properties":{"x":{"oneOf":[{"type":"string"},{"type":"integer"}]},"y":{"allOf":[{"type":"object"}]}}}"#
        XCTAssertEqual(ToolSchemaCompaction.prepare(s, compact: true), s)
    }

    func testSmallSchemaWithReachableRefIsPreserved() {
        // A reachable $ref keeps its $defs entry; structure preserved.
        let s = ##"{"type":"object","properties":{"u":{"$ref":"#/$defs/User"}},"$defs":{"User":{"type":"object","properties":{"name":{"type":"string"}}}}}"##
        let out = ToolSchemaCompaction.prepare(s, compact: true)
        let o = obj(out)
        XCTAssertNotNil((o["$defs"] as? [String: Any])?["User"], "reachable def kept")
        let props = o["properties"] as? [String: Any]
        XCTAssertEqual(((props?["u"] as? [String: Any])?["$ref"]) as? String, "#/$defs/User")
    }

    // MARK: prune unreachable definitions (#23357)

    func testPruneRemovesUnreachableDefinitionsOnly() {
        let s = ##"{"type":"object","properties":{"u":{"$ref":"#/$defs/Used"}},"$defs":{"Used":{"type":"string"},"Unused":{"type":"integer"}}}"##
        let out = ToolSchemaCompaction.prepare(s, compact: false)
        let defs = obj(out)["$defs"] as? [String: Any]
        XCTAssertNotNil(defs?["Used"], "reachable def retained")
        XCTAssertNil(defs?["Unused"], "unreachable def pruned")
    }

    func testPruneFollowsTransitiveRefsAndDropsEmptyTable() {
        // A -> B chain: both reachable. C unreferenced. After pruning C, table
        // still present. With ALL unreachable, the table is removed entirely.
        let chain = ##"{"properties":{"a":{"$ref":"#/$defs/A"}},"$defs":{"A":{"properties":{"b":{"$ref":"#/$defs/B"}}},"B":{"type":"string"},"C":{"type":"number"}}}"##
        let defs = obj(ToolSchemaCompaction.prepare(chain, compact: false))["$defs"] as? [String: Any]
        XCTAssertEqual(Set(defs!.keys), ["A", "B"], "transitive A,B kept; C pruned")

        let allUnused = #"{"type":"object","$defs":{"X":{"type":"string"}}}"#
        XCTAssertNil(obj(ToolSchemaCompaction.prepare(allUnused, compact: false))["$defs"],
                     "empty definition table removed")
    }

    // MARK: review fixes — fail-closed ref decode + budget fast-path

    func testParseLocalRefFailsClosedOnMalformedPercentEncoding() {
        // A bare '%' is invalid percent-encoding → upstream rejects the ref; the
        // port must too (regression for the `?? fragment` fail-open bug).
        XCTAssertNil(ToolSchemaCompaction.parseLocalDefinitionRef("#/$defs/Foo%"),
                     "malformed percent-encoding → not a recognized local ref")
        XCTAssertEqual(ToolSchemaCompaction.parseLocalDefinitionRef("#/$defs/Foo")?.name, "Foo")
        XCTAssertEqual(ToolSchemaCompaction.parseLocalDefinitionRef("#/definitions/Bar")?.table, "definitions")
        XCTAssertNil(ToolSchemaCompaction.parseLocalDefinitionRef("https://x/$defs/Y"),
                     "external ref → not local")
    }

    func testCompactionNotSkippedWhenNormalizedExceedsRawBudget() {
        // Slash-heavy descriptions: raw bytes < 4000 but JSON-normalized bytes
        // (each '/' escaped to '\/') exceed 4000. The old raw-length fast path
        // wrongly SKIPPED compaction here; the parse-and-measure path must run it.
        let slashes = String(repeating: "/", count: 220)
        var props: [String] = []
        for i in 0..<12 { props.append("\"p\(i)\":{\"type\":\"string\",\"description\":\"\(slashes)\"}") }
        let s = "{\"type\":\"object\",\"properties\":{\(props.joined(separator: ","))}}"
        XCTAssertLessThanOrEqual(s.utf8.count, ToolSchemaCompaction.maxBytes,
                                 "fixture raw length is under budget (old fast path would skip)")
        XCTAssertGreaterThan(normLen(s), ToolSchemaCompaction.maxBytes,
                             "fixture normalized length is over budget")
        let out = ToolSchemaCompaction.prepare(s, compact: true)
        XCTAssertFalse(out.contains("description"), "compaction ran despite raw<budget")
        XCTAssertLessThanOrEqual(normLen(out), ToolSchemaCompaction.maxBytes, "shrunk under budget")
    }

    func testNoTransformReturnsVerbatim() {
        // A small schema with a $defs substring only inside a description (no real
        // table) is returned byte-for-byte (no needless renormalization).
        let s = #"{"type":"object","properties":{"x":{"type":"number","description":"mentions $defs"}}}"#
        XCTAssertEqual(ToolSchemaCompaction.prepare(s, compact: true), s)
    }

    // MARK: compaction passes (#23904)

    func testCompactionStripsDescriptionsFirst() {
        // Build a schema over budget purely via long descriptions; the first
        // pass (strip descriptions) should bring it under budget, keeping
        // structure (properties) intact.
        var props: [String] = []
        let longDesc = String(repeating: "x", count: 80)
        for i in 0..<80 { props.append("\"p\(i)\":{\"type\":\"string\",\"description\":\"\(longDesc)\"}") }
        let big = "{\"type\":\"object\",\"properties\":{\(props.joined(separator: ","))}}"
        XCTAssertGreaterThan(normLen(big), ToolSchemaCompaction.maxBytes, "fixture is over budget")

        let out = ToolSchemaCompaction.prepare(big, compact: true)
        XCTAssertLessThanOrEqual(normLen(out), ToolSchemaCompaction.maxBytes, "compacted under budget")
        XCTAssertFalse(out.contains("\"description\""), "descriptions stripped")
        XCTAssertNotNil(obj(out)["properties"], "top-level property surface preserved")
        // No further passes were needed → compositions/defs untouched conceptually.
    }

    func testStripDescriptionsPassRemovesNestedDescriptions() {
        let s = obj(#"{"description":"top","properties":{"a":{"type":"string","description":"inner"}},"items":{"description":"item"}}"#)
        let out = ToolSchemaCompaction.stripDescriptions(s) as! [String: Any]
        XCTAssertNil(out["description"])
        let a = (out["properties"] as? [String: Any])?["a"] as? [String: Any]
        XCTAssertNil(a?["description"], "nested property description stripped")
        XCTAssertNil((out["items"] as? [String: Any])?["description"], "items description stripped")
    }

    func testDropDefinitionsRewritesLocalRefsToEmpty() {
        let s = obj(##"{"properties":{"u":{"$ref":"#/$defs/User"},"ext":{"$ref":"https://x/y"}},"$defs":{"User":{"type":"object"}}}"##)
        let out = ToolSchemaCompaction.dropDefinitions(s) as! [String: Any]
        XCTAssertNil(out["$defs"], "definition table dropped")
        let props = out["properties"] as! [String: Any]
        XCTAssertTrue((props["u"] as? [String: Any])?.isEmpty == true, "local def ref → empty schema")
        // A non-local ref is NOT a definition ref → left intact.
        XCTAssertEqual((props["ext"] as? [String: Any])?["$ref"] as? String, "https://x/y")
    }

    func testCollapseDeepObjectsAtDepthThreshold() {
        // Depth counts children: root(0) → a(1) → b(2) → deep(3). The complex
        // object `deep` at depth 3 collapses to {}; `b` at depth 2 is preserved.
        let s = obj(#"{"properties":{"a":{"properties":{"b":{"properties":{"deep":{"type":"object","properties":{"z":{"type":"string"}}}}}}}}}"#)
        let out = ToolSchemaCompaction.collapseDeepFromRoot(s) as! [String: Any]
        func props(_ d: Any?) -> [String: Any]? { (d as? [String: Any])?["properties"] as? [String: Any] }
        let a = props(out)?["a"]
        let b = props(a)?["b"]
        XCTAssertNotNil(props(b), "b at depth 2 still has its properties (not collapsed)")
        let deep = props(b)?["deep"] as? [String: Any]
        XCTAssertEqual(deep?.isEmpty, true, "complex object at depth>=3 collapsed to {}")
    }

    func testPruneCompositionsCollapsesCompositionObjects() {
        let s = obj(#"{"properties":{"x":{"oneOf":[{"type":"string"}]},"y":{"type":"integer"}}}"#)
        let out = ToolSchemaCompaction.pruneCompositions(s) as! [String: Any]
        let props = out["properties"] as! [String: Any]
        XCTAssertEqual((props["x"] as? [String: Any])?.isEmpty, true, "oneOf object collapsed")
        XCTAssertEqual((props["y"] as? [String: Any])?["type"] as? String, "integer", "non-composition kept")
    }

    // MARK: tool router integration + web-search opt-out (#24660)

    func testSpecsCompactsLargeSchemaButNotWebSearch() async {
        struct BigTool: Tool {
            let name = "big"; let parallelSafe = true
            func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
                ToolResult(callId: call.callId, output: "", success: true, truncated: false)
            }
            var jsonSchema: String {
                var props: [String] = []
                let d = String(repeating: "y", count: 80)
                for i in 0..<80 { props.append("\"p\(i)\":{\"type\":\"string\",\"description\":\"\(d)\"}") }
                return "{\"type\":\"object\",\"properties\":{\(props.joined(separator: ","))}}"
            }
        }
        struct BigWebSearch: Tool {
            let name = "web_search"; let parallelSafe = true
            let compactInputSchema = false
            func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
                ToolResult(callId: call.callId, output: "", success: true, truncated: false)
            }
            var jsonSchema: String {
                var props: [String] = []
                let d = String(repeating: "y", count: 80)
                for i in 0..<80 { props.append("\"p\(i)\":{\"type\":\"string\",\"description\":\"\(d)\"}") }
                return "{\"type\":\"object\",\"properties\":{\(props.joined(separator: ","))}}"
            }
        }
        let router = ToolRouter(limits: Limits())
        await router.register(BigTool())
        await router.register(BigWebSearch())
        let specs = await router.specs()
        let big = specs.first { $0.name == "big" }!
        let ws = specs.first { $0.name == "web_search" }!
        XCTAssertFalse(big.parametersJSON.contains("\"description\""), "big tool schema compacted")
        XCTAssertTrue(ws.parametersJSON.contains("\"description\""), "web_search opted out → verbatim")
    }
}
