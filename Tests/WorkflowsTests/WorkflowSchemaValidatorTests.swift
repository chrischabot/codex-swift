import XCTest
import Foundation
@testable import Workflows
import Tools
import ProtocolModel

/// Adversarial verification for Task #1 — schema validation at the tool
/// boundary. The contract under test: `final_answer` arguments are validated
/// against the `agent({schema})` JSON Schema, a nonconforming submission is
/// rejected (so the subagent retries in-turn), and the capture box only ever
/// holds a schema-valid object.
final class WorkflowSchemaValidatorTests: XCTestCase {

    private func valid(_ instance: String, _ schema: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = WorkflowSchemaValidator.validate(instanceJSON: instance, schemaJSON: schema)
        XCTAssertTrue(e.isEmpty, "expected valid, got: \(e)", file: file, line: line)
    }
    private func invalid(_ instance: String, _ schema: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = WorkflowSchemaValidator.validate(instanceJSON: instance, schemaJSON: schema)
        XCTAssertFalse(e.isEmpty, "expected violations, got none", file: file, line: line)
    }

    // MARK: type discrimination

    func testRequiredAndTypes() {
        let s = #"{"type":"object","required":["title","count"],"properties":{"title":{"type":"string"},"count":{"type":"integer"}}}"#
        valid(#"{"title":"x","count":3}"#, s)
        invalid(#"{"count":3}"#, s)                 // missing title
        invalid(#"{"title":"x"}"#, s)               // missing count
        invalid(#"{"title":5,"count":3}"#, s)       // title wrong type
        invalid(#"{"title":"x","count":"3"}"#, s)   // count wrong type
    }

    /// The classic JSONSerialization trap: `true`/`false` bridge to NSNumber.
    /// A boolean must NOT satisfy integer/number, and 1 must NOT satisfy boolean.
    func testBooleanNumberAmbiguity() {
        valid("true", #"{"type":"boolean"}"#)
        valid("false", #"{"type":"boolean"}"#)
        invalid("true", #"{"type":"integer"}"#)
        invalid("true", #"{"type":"number"}"#)
        invalid("1", #"{"type":"boolean"}"#)
        invalid("0", #"{"type":"boolean"}"#)
    }

    func testIntegerVsNumber() {
        valid("3", #"{"type":"integer"}"#)
        valid("3", #"{"type":"number"}"#)
        valid("3.5", #"{"type":"number"}"#)
        invalid("3.5", #"{"type":"integer"}"#)
        valid("3.0", #"{"type":"integer"}"#)   // integral double is an integer
    }

    func testNullHandling() {
        valid("null", #"{"type":"null"}"#)
        invalid("null", #"{"type":"string"}"#)
        valid("null", #"{"type":["string","null"]}"#)   // union type
        // a null value for an object property whose schema forbids null
        invalid(#"{"name":null}"#, #"{"type":"object","properties":{"name":{"type":"string"}}}"#)
    }

    func testTypeUnionArray() {
        let s = #"{"type":["string","integer"]}"#
        valid("\"hi\"", s); valid("42", s)
        invalid("true", s); invalid("3.5", s); invalid("{}", s)
    }

    // MARK: nesting

    func testNestedObjectsAndArrays() {
        let s = #"""
        {"type":"object","required":["findings"],"properties":{
          "findings":{"type":"array","items":{"type":"object","required":["file","line"],
            "properties":{"file":{"type":"string"},"line":{"type":"integer"}}}}}}
        """#
        valid(#"{"findings":[{"file":"a.ts","line":1},{"file":"b.ts","line":2}]}"#, s)
        invalid(#"{"findings":[{"file":"a.ts","line":1},{"file":"b.ts"}]}"#, s)        // 2nd missing line
        invalid(#"{"findings":[{"file":"a.ts","line":"1"}]}"#, s)                       // line wrong type
        invalid(#"{"findings":{"file":"a.ts","line":1}}"#, s)                           // findings not array
    }

    func testTupleItems() {
        let s = #"{"type":"array","items":[{"type":"string"},{"type":"integer"}]}"#
        valid(#"["a",1]"#, s)
        invalid(#"[1,1]"#, s)   // first slot must be string
    }

    // MARK: enum / const / combinators

    func testEnumAndConst() {
        valid("\"a\"", #"{"enum":["a","b","c"]}"#)
        invalid("\"z\"", #"{"enum":["a","b","c"]}"#)
        valid("true", #"{"const":true}"#)
        invalid("false", #"{"const":true}"#)
    }

    func testAnyOfOneOf() {
        let anyOf = #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#
        valid("\"x\"", anyOf); valid("5", anyOf); invalid("true", anyOf)
        // oneOf: exactly one. A value that is both string and enum-of-strings → both match → fail.
        let oneOf = #"{"oneOf":[{"type":"string"},{"type":"integer"}]}"#
        valid("\"x\"", oneOf); invalid("3.5", oneOf)
    }

    /// oneOf with 2+ matching members must fail (drives the matched>=2 branch).
    func testOneOfMultipleMatchesFails() {
        // "x" matches both {type:string} and {enum:["x","y"]} → 2 matches → fail.
        invalid("\"x\"", #"{"oneOf":[{"type":"string"},{"enum":["x","y"]}]}"#)
        // a value matching none also fails.
        invalid("\"z\"", #"{"oneOf":[{"enum":["a"]},{"enum":["b"]}]}"#)
    }

    func testAllOf() {
        let s = #"{"allOf":[{"type":"object","required":["a"]},{"required":["b"]}]}"#
        valid(#"{"a":1,"b":2}"#, s)
        invalid(#"{"a":1}"#, s)   // missing b from the second member
        // allOf:false forbids everything.
        invalid("1", #"{"allOf":[false]}"#)
    }

    /// Boolean-form combinator members must not silently disable the constraint.
    func testBooleanFormCombinatorMembers() {
        // anyOf containing only `false` matches nothing → always invalid.
        invalid("5", #"{"anyOf":[false]}"#)
        // anyOf with a `false` plus a real type still enforces the real type.
        valid("\"s\"", #"{"anyOf":[false,{"type":"string"}]}"#)
        invalid("5", #"{"anyOf":[false,{"type":"string"}]}"#)
        // anyOf containing `true` accepts anything.
        valid("5", #"{"anyOf":[true]}"#)
    }

    /// enum/const with object and array values exercise deep jsonEqual.
    func testEnumConstDeepEquality() {
        valid(#"{"a":1,"b":[2,3]}"#, #"{"const":{"a":1,"b":[2,3]}}"#)
        invalid(#"{"a":1,"b":[2,4]}"#, #"{"const":{"a":1,"b":[2,3]}}"#)
        valid(#"[1,2]"#, #"{"enum":[[1,2],[3,4]]}"#)
        invalid(#"[1,3]"#, #"{"enum":[[1,2],[3,4]]}"#)
    }

    func testAdditionalPropertiesObjectSubschema() {
        let s = #"{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":{"type":"number"}}"#
        valid(#"{"a":"x","b":1,"c":2.5}"#, s)
        invalid(#"{"a":"x","b":"notnum"}"#, s)   // extra prop must be a number
    }

    func testAdditionalPropertiesFalseNoPropertiesKey() {
        // No `properties` at all → every key is "unknown" → all rejected.
        invalid(#"{"a":1}"#, #"{"type":"object","additionalProperties":false}"#)
        valid("{}", #"{"type":"object","additionalProperties":false}"#)
    }

    func testNestedAdditionalPropertiesFalse() {
        let s = #"{"type":"object","properties":{"inner":{"type":"object","properties":{"a":{"type":"integer"}},"additionalProperties":false}}}"#
        valid(#"{"inner":{"a":1}}"#, s)
        invalid(#"{"inner":{"a":1,"x":2}}"#, s)
    }

    // MARK: additionalProperties

    func testAdditionalPropertiesFalse() {
        let s = #"{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false}"#
        valid(#"{"a":"x"}"#, s)
        invalid(#"{"a":"x","b":1}"#, s)
        // default (no additionalProperties) allows extras
        valid(#"{"a":"x","b":1}"#, #"{"type":"object","properties":{"a":{"type":"string"}}}"#)
    }

    // MARK: degenerate inputs

    func testMalformedInstanceIsRejected() {
        invalid("{not json", #"{"type":"object"}"#)
    }
    func testUnparseableSchemaPassesThrough() {
        // A broken author schema must not hard-block the subagent.
        valid(#"{"anything":true}"#, "{not a schema")
    }
    func testSchemaWithoutTypeChecksStructureOnly() {
        valid(#"{"x":1}"#, #"{"required":["x"]}"#)
        invalid(#"{"y":1}"#, #"{"required":["x"]}"#)
    }
    func testErrorReportIsBounded() {
        // 30 required keys all missing → report capped at 20 (+ overflow line).
        let keys = (0..<30).map { "\"k\($0)\"" }.joined(separator: ",")
        let s = "{\"type\":\"object\",\"required\":[\(keys)]}"
        let e = WorkflowSchemaValidator.validate(instanceJSON: "{}", schemaJSON: s)
        XCTAssertLessThanOrEqual(e.count, 21)
        XCTAssertTrue(e.contains { $0.contains("more") })
    }

    // MARK: tool boundary

    func testFinalAnswerToolRejectsNonconformingAndDoesNotCapture() async throws {
        let box = CaptureBox()
        let tool = FinalAnswerTool(
            schema: #"{"type":"object","required":["ok"],"properties":{"ok":{"type":"boolean"}}}"#,
            box: box)
        let bad = ToolCall(callId: "c1", name: "final_answer", argumentsJSON: #"{"ok":"yes"}"#)
        let r1 = try await tool.run(bad, cwd: ".")
        XCTAssertFalse(r1.success)
        XCTAssertTrue(r1.output.contains("schema"))
        XCTAssertNil(box.value, "box must NOT capture a nonconforming submission")

        let good = ToolCall(callId: "c2", name: "final_answer", argumentsJSON: #"{"ok":true}"#)
        let r2 = try await tool.run(good, cwd: ".")
        XCTAssertTrue(r2.success)
        XCTAssertEqual(box.value, #"{"ok":true}"#)
    }

    func testFinalAnswerToolErrorOutputIsValidJSON() async throws {
        // The rejection output must itself be valid JSON (newlines escaped).
        let box = CaptureBox()
        let tool = FinalAnswerTool(schema: #"{"type":"object","required":["a","b"]}"#, box: box)
        let r = try await tool.run(ToolCall(callId: "c", name: "final_answer", argumentsJSON: "{}"), cwd: ".")
        let parsed = try JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["accepted"] as? Bool, false)
        XCTAssertNotNil(parsed?["error"] as? String)
    }
}
