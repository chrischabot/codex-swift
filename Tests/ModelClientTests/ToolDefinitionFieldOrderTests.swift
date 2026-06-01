import XCTest
@testable import ModelClient

/// tools-router audit (v13) Finding 3 (minor, ordering): the request body must
/// preserve upstream's serde field ordering for the tool-definition subtree.
///
/// `JSONSerialization`'s `.sortedKeys` alphabetizes EVERY object, reordering each
/// nested `JsonSchema` to `{"description":…,"type":…}` — the opposite of
/// upstream's struct order where `type` is the first field
/// (`tools/src/json_schema.rs:33-55`: type, description, enum, items,
/// properties, required, additionalProperties, anyOf). `serializeBody` keeps
/// top-level / map keys sorted (matching the serde `BTreeMap` property order)
/// but emits each schema object's keys in canonical serde order so the
/// tool-definition bytes are byte-identical to upstream (prompt-cache parity).
final class ToolDefinitionFieldOrderTests: XCTestCase {

    private func render(_ body: [String: Any]) throws -> String {
        String(decoding: try OpenAIResponsesClient.serializeBody(body), as: UTF8.self)
    }

    // A function tool's `parameters` schema and every nested property schema put
    // `type` before `description` (serde order), not alphabetical.
    func testToolParameterSchemaIsTypeFirst() throws {
        let body: [String: Any] = [
            "tools": [
                [
                    "type": "function",
                    "name": "do_thing",
                    "description": "does a thing",
                    "strict": false,
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "description": "the path",
                                "type": "string",
                            ],
                        ],
                        "required": ["path"],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ]
        let json = try render(body)

        // The `parameters` object: type before properties before required
        // before additionalProperties (canonical JsonSchema order).
        XCTAssertTrue(json.contains(#""parameters":{"type":"object","properties":"#),
            "parameters schema must lead with type (serde order), got: \(json)")
        // The nested property schema: type before description (NOT alphabetical
        // description-before-type that .sortedKeys would produce).
        XCTAssertTrue(json.contains(#""path":{"type":"string","description":"the path"}"#),
            "nested property schema must be type-first, got: \(json)")
        XCTAssertFalse(json.contains(#""description":"the path","type":"string""#),
            "must NOT alphabetize the nested schema (description-before-type)")
    }

    // Non-schema parts of the body keep deterministic sorted keys (matching
    // upstream's serde BTreeMap / struct ordering expectations for the cache key
    // prefix). Top-level keys are alphabetical.
    func testNonSchemaKeysAreSorted() throws {
        let body: [String: Any] = [
            "model": "gpt-5",
            "input": [] as [Any],
            "stream": true,
            "store": false,
        ]
        let json = try render(body)
        XCTAssertEqual(json, #"{"input":[],"model":"gpt-5","store":false,"stream":true}"#)
    }

    // `properties` is a name→schema MAP: its keys (property names) stay
    // alphabetical (upstream BTreeMap), while each value is a type-first schema.
    func testPropertyMapKeysStaySortedValuesAreSchemas() throws {
        let body: [String: Any] = [
            "tools": [
                [
                    "type": "function",
                    "name": "t",
                    "description": "d",
                    "strict": true,
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "zebra": ["description": "z", "type": "string"],
                            "alpha": ["description": "a", "type": "number"],
                        ],
                    ],
                ],
            ],
        ]
        let json = try render(body)
        // alpha precedes zebra (sorted map keys) AND each value is type-first.
        XCTAssertTrue(json.contains(
            #""properties":{"alpha":{"type":"number","description":"a"},"zebra":{"type":"string","description":"z"}}"#),
            "property map keys must stay sorted with type-first schema values, got: \(json)")
    }

    // A `custom` (freeform) tool entry carries no `parameters`, so its keys are
    // simply sorted (no schema subtree) — should not crash and stays sorted.
    func testFreeformToolHasNoSchemaSubtree() throws {
        let body: [String: Any] = [
            "tools": [
                [
                    "type": "custom",
                    "name": "apply_patch",
                    "description": "patch",
                    "format": ["type": "grammar", "syntax": "lark", "definition": "x"],
                ],
            ],
        ]
        let json = try render(body)
        // No `parameters` → keys sorted; `format` is a plain object (sorted).
        XCTAssertTrue(json.contains(#""format":{"definition":"x","syntax":"lark","type":"grammar"}"#),
            "freeform format is not a JsonSchema subtree; keys stay sorted, got: \(json)")
    }
}
