import Foundation

/// Faithful port of the wire-relevant parts of upstream
/// `codex-rs/tools/src/json_schema.rs` (June-2026 sync, PRs #23357/#23904/#24660/#22380):
///
/// - `prune_unreachable_definitions` — drop `$defs`/`definitions` entries no
///   `$ref` reaches (always).
/// - `compact_large_tool_schema` — best-effort shrink of schemas over the
///   ~1k-token budget (>4000 normalized bytes), via four increasingly lossy
///   passes, run only while still over budget.
///
/// **Intentional divergence:** the port does NOT port `sanitize_json_schema`.
/// That pass exists only to coerce arbitrary schemas into upstream's *restricted*
/// typed `JsonSchema` representation; the Swift port forwards tool input schemas
/// as opaque JSON (pass-through), so `oneOf`/`allOf`/`$ref`/`$defs`/`const`/`enum`
/// already reach the model verbatim — sanitizing would only *lose* fidelity.
/// Unknown/empty schemas already default to a permissive object (#22380) at the
/// tool layer (`ToolRouter`/`McpToolProxy`).
public enum ToolSchemaCompaction {
    static let maxBytes = 4_000
    static let maxDepth = 3
    static let definitionTableKeys = ["$defs", "definitions"]
    static let schemaChildKeys = ["items", "anyOf", "oneOf", "allOf"]
    static let compositionKeys = ["anyOf", "oneOf", "allOf"]

    struct Pointer: Hashable { let table: String; let name: String }

    /// Prune unreachable definitions and, when `compact`, shrink schemas over the
    /// ~1k-token budget. Returns the input string **unchanged** unless an actual
    /// transform occurs — so hand-authored schemas keep their exact bytes (no
    /// number/slash renormalization) in the common case.
    ///
    /// NOTE on the budget: raw string length is NOT a safe upper bound for the
    /// normalized length (JSON re-serialization can GROW the form — slash-escaping
    /// `http://`→`http:\/\/`, float expansion `0.1`→`0.10000000000000001`), so
    /// when `compact` is requested we parse and measure `normalizedLen` rather than
    /// short-circuiting on `json.utf8.count`. When a transform does run, the schema
    /// is re-serialized via JSONSerialization, which (like upstream's serde
    /// round-trip) renormalizes numeric literals and escapes slashes.
    public static func prepare(_ json: String, compact: Bool) -> String {
        // Cheap pre-screen: a real definition table is needed before pruning can
        // change anything; a "$defs" substring inside a description does not count.
        let mayHaveDefs = json.contains("\"$defs\"") || json.contains("\"definitions\"")
        guard mayHaveDefs || compact else { return json }

        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]) else { return json }
        var obj: Any = parsed
        var changed = false

        if mayHaveDefs, let map = obj as? [String: Any],
           definitionTableKeys.contains(where: { map[$0] != nil }) {
            obj = pruneUnreachableDefinitions(obj)
            changed = true
        }
        if compact && normalizedLen(obj) > maxBytes {
            obj = compactLargeToolSchema(obj)
            changed = true
        }
        guard changed else { return json }

        guard let out = try? JSONSerialization.data(
                  withJSONObject: obj, options: [.fragmentsAllowed, .sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return json }
        return s
    }

    // MARK: budget

    static func normalizedLen(_ obj: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]))?.count ?? 0
    }

    static func compactLargeToolSchema(_ value: Any) -> Any {
        var v = value
        let passes: [(Any) -> Any] = [
            stripDescriptions, dropDefinitions, collapseDeepFromRoot, pruneCompositions,
        ]
        for pass in passes {
            if normalizedLen(v) <= maxBytes { break }
            v = pass(v)
        }
        return v
    }

    // MARK: child traversal

    /// Visit every schema child of `map` (read-only). Mirrors upstream
    /// `for_each_schema_child`: properties values, items/anyOf/oneOf/allOf,
    /// non-boolean additionalProperties, and (when `includeDefs`) definition tables.
    static func forEachSchemaChild(_ map: [String: Any], includeDefs: Bool, _ visit: (Any) -> Void) {
        if let props = map["properties"] as? [String: Any] { for v in props.values { visit(v) } }
        for key in schemaChildKeys { if let v = map[key] { visit(v) } }
        if let ap = map["additionalProperties"], !(ap is Bool) { visit(ap) }
        if includeDefs {
            for t in definitionTableKeys {
                if let d = map[t] as? [String: Any] { for v in d.values { visit(v) } }
            }
        }
    }

    /// Transform each schema child of `map`, returning a new dict.
    static func mapSchemaChildren(_ map: [String: Any], includeDefs: Bool,
                                  _ f: (Any) -> Any) -> [String: Any] {
        var m = map
        if let props = m["properties"] as? [String: Any] {
            m["properties"] = props.mapValues(f)
        }
        for key in schemaChildKeys { if let v = m[key] { m[key] = f(v) } }
        if let ap = m["additionalProperties"], !(ap is Bool) { m["additionalProperties"] = f(ap) }
        if includeDefs {
            for t in definitionTableKeys {
                if let d = m[t] as? [String: Any] { m[t] = d.mapValues(f) }
            }
        }
        return m
    }

    // MARK: compaction passes

    static func stripDescriptions(_ value: Any) -> Any {
        if let arr = value as? [Any] { return arr.map(stripDescriptions) }
        if var map = value as? [String: Any] {
            map.removeValue(forKey: "description")
            return mapSchemaChildren(map, includeDefs: true, stripDescriptions)
        }
        return value
    }

    static func dropDefinitions(_ value: Any) -> Any {
        let rewritten = rewriteDefinitionRefsToEmpty(value)
        guard var map = rewritten as? [String: Any] else { return rewritten }
        for t in definitionTableKeys { map.removeValue(forKey: t) }
        return map
    }

    static func rewriteDefinitionRefsToEmpty(_ value: Any) -> Any {
        if let arr = value as? [Any] { return arr.map(rewriteDefinitionRefsToEmpty) }
        if let map = value as? [String: Any] {
            if let r = map["$ref"] as? String, parseLocalDefinitionRef(r) != nil {
                return [String: Any]()
            }
            return mapSchemaChildren(map, includeDefs: false, rewriteDefinitionRefsToEmpty)
        }
        return value
    }

    static func collapseDeepFromRoot(_ value: Any) -> Any { collapseDeep(value, depth: 0) }
    static func collapseDeep(_ value: Any, depth: Int) -> Any {
        if let arr = value as? [Any] { return arr.map { collapseDeep($0, depth: depth) } }
        if let map = value as? [String: Any] {
            if depth >= maxDepth && isComplexSchemaObject(map) { return [String: Any]() }
            return mapSchemaChildren(map, includeDefs: false) { collapseDeep($0, depth: depth + 1) }
        }
        return value
    }

    static func pruneCompositions(_ value: Any) -> Any {
        if let arr = value as? [Any] { return arr.map(pruneCompositions) }
        if let map = value as? [String: Any] {
            if hasCompositionKeyword(map) { return [String: Any]() }
            return mapSchemaChildren(map, includeDefs: false, pruneCompositions)
        }
        return value
    }

    static func isComplexSchemaObject(_ map: [String: Any]) -> Bool {
        schemaChildKeys.contains { map[$0] != nil }
            || map["properties"] != nil || map["additionalProperties"] != nil || map["$ref"] != nil
    }
    static func hasCompositionKeyword(_ map: [String: Any]) -> Bool {
        compositionKeys.contains { map[$0] != nil }
    }

    // MARK: prune unreachable definitions

    static func pruneUnreachableDefinitions(_ value: Any) -> Any {
        guard var map = value as? [String: Any] else { return value }
        let reachable = collectReachableDefinitions(map)
        for table in definitionTableKeys {
            guard let defs = map[table] as? [String: Any] else { continue }
            let kept = defs.filter { reachable.contains(Pointer(table: table, name: $0.key)) }
            if kept.isEmpty { map.removeValue(forKey: table) } else { map[table] = kept }
        }
        return map
    }

    static func collectReachableDefinitions(_ root: [String: Any]) -> Set<Pointer> {
        var reachable = Set<Pointer>()
        var pending: [Pointer] = []
        collectRefsOutsideDefinitions(root, &pending)
        while let p = pending.popLast() {
            if !reachable.insert(p).inserted { continue }
            if let table = root[p.table] as? [String: Any], let def = table[p.name] {
                collectRefs(def, &pending)
            }
        }
        return reachable
    }

    static func collectRefsOutsideDefinitions(_ value: Any, _ refs: inout [Pointer]) {
        if let arr = value as? [Any] { for v in arr { collectRefsOutsideDefinitions(v, &refs) }; return }
        if let map = value as? [String: Any] {
            collectRefFromMap(map, &refs)
            forEachSchemaChild(map, includeDefs: false) { collectRefsOutsideDefinitions($0, &refs) }
        }
    }
    static func collectRefs(_ value: Any, _ refs: inout [Pointer]) {
        if let arr = value as? [Any] { for v in arr { collectRefs(v, &refs) }; return }
        if let map = value as? [String: Any] {
            collectRefFromMap(map, &refs)
            for v in map.values { collectRefs(v, &refs) }
        }
    }
    static func collectRefFromMap(_ map: [String: Any], _ refs: inout [Pointer]) {
        if let r = map["$ref"] as? String, let p = parseLocalDefinitionRef(r) { refs.append(p) }
    }

    /// Parse a local definition `$ref` such as `#/$defs/User` (or a nested
    /// `#/$defs/User/properties/name`, keeping the parent `User` reachable).
    static func parseLocalDefinitionRef(_ ref: String) -> Pointer? {
        guard ref.hasPrefix("#") else { return nil }
        let fragment = String(ref.dropFirst())
        // Fail CLOSED on malformed percent-encoding (upstream `urlencoding::decode
        // (...).ok()?`): an undecodable fragment is NOT a recognized local ref.
        guard let decoded = fragment.removingPercentEncoding else { return nil }
        guard decoded.hasPrefix("/") else { return nil }
        let tokens = decoded.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { jsonPointerUnescape(String($0)) }
        guard tokens.count >= 2, definitionTableKeys.contains(tokens[0]) else { return nil }
        return Pointer(table: tokens[0], name: tokens[1])
    }
    static func jsonPointerUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}
