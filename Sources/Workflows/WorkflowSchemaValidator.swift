import Foundation

/// Minimal, dependency-free JSON-Schema validator covering the subset that
/// workflow `agent({schema})` calls actually use: `type` (incl. union arrays),
/// `required`, `properties`, `items` (single-schema + tuple), `enum`,
/// `additionalProperties` (bool), and the `anyOf`/`oneOf`/`allOf` combinators,
/// recursively. It exists to make the spec's central guarantee real — a
/// subagent's `final_answer` arguments are validated *at the tool boundary*,
/// and a nonconforming response is rejected (forcing an in-turn model retry)
/// before the value ever reaches the orchestration script.
///
/// Not a complete Draft-2020 implementation: numeric/string/array constraints
/// like `minimum`, `pattern`, `minItems` are intentionally out of scope (no
/// real workflow schema has relied on them). Unknown keywords are ignored, so
/// stricter schemas simply validate more loosely rather than erroring.
public enum WorkflowSchemaValidator {

    /// Validate `instanceJSON` (the raw arguments string) against `schemaJSON`.
    /// Returns an empty array when valid, else a bounded list of human-readable
    /// violation messages rooted at JSON-pointer-ish paths.
    public static func validate(instanceJSON: String, schemaJSON: String) -> [String] {
        guard let schemaAny = parse(schemaJSON) else {
            // An unparseable schema can't constrain anything — treat as pass so
            // a malformed author schema never hard-blocks a subagent.
            return []
        }
        guard let schema = schemaAny as? [String: Any] else {
            return []   // non-object schema (e.g. `true`) accepts everything
        }
        guard let instance = parse(instanceJSON) else {
            return ["root: arguments are not valid JSON"]
        }
        var errs: [String] = []
        check(instance, against: schema, at: "root", into: &errs)
        // Bound the report so a deeply-wrong object can't produce a megabyte of
        // errors; the first handful is enough to steer a retry.
        if errs.count > 20 { errs = Array(errs.prefix(20)) + ["… (\(errs.count - 20) more)"] }
        return errs
    }

    // MARK: - core

    private static func check(_ value: Any, against schema: [String: Any], at path: String, into errs: inout [String]) {
        // Combinators first — they wrap subschemas. Members may be object
        // schemas OR boolean schemas (`true`/`false`); a non-object member must
        // not silently disable the whole constraint (it would over-accept).
        if let anyOf = schema["anyOf"] as? [Any] {
            if !anyOf.contains(where: { subschemaValid(value, $0) }) {
                errs.append("\(path): does not match any of the allowed schemas (anyOf)")
            }
        }
        if let oneOf = schema["oneOf"] as? [Any] {
            let matches = oneOf.reduce(0) { $0 + (subschemaValid(value, $1) ? 1 : 0) }
            if matches != 1 { errs.append("\(path): must match exactly one schema (oneOf), matched \(matches)") }
        }
        if let allOf = schema["allOf"] as? [Any] {
            for sub in allOf {
                if let obj = sub as? [String: Any] { check(value, against: obj, at: path, into: &errs) }
                else if sub as? Bool == false { errs.append("\(path): schema member forbids all values (allOf:false)") }
            }
        }

        // enum
        if let en = schema["enum"] as? [Any] {
            if !en.contains(where: { jsonEqual($0, value) }) {
                errs.append("\(path): value is not one of the allowed enum values")
            }
        }
        // const
        if let c = schema["const"], !jsonEqual(c, value) {
            errs.append("\(path): value does not equal the required const")
        }

        // type (string or array-of-strings)
        let types: [String]
        if let t = schema["type"] as? String { types = [t] }
        else if let ts = schema["type"] as? [String] { types = ts }
        else { types = [] }

        if !types.isEmpty {
            let matched = types.contains { typeMatches(value, $0) }
            if !matched {
                errs.append("\(path): expected type \(types.count == 1 ? types[0] : "one of \(types)"), got \(jsonTypeName(value))")
                return   // wrong type → don't cascade into property/item checks
            }
        }

        // object constraints
        if let obj = asObject(value) {
            if let required = schema["required"] as? [String] {
                for key in required where obj[key] == nil {
                    errs.append("\(path): missing required property \"\(key)\"")
                }
            }
            let props = schema["properties"] as? [String: Any]
            if let props {
                for (key, sub) in props {
                    guard let subSchema = sub as? [String: Any], let child = obj[key] else { continue }
                    check(child, against: subSchema, at: "\(path)/\(key)", into: &errs)
                }
            }
            // additionalProperties: `false` rejects unknown keys; an object
            // subschema validates each unknown value against it.
            let known: Set<String> = Set(props.map { Array($0.keys) } ?? [])
            if let ap = schema["additionalProperties"] as? Bool, ap == false {
                for key in obj.keys where !known.contains(key) {
                    errs.append("\(path): unexpected property \"\(key)\" (additionalProperties:false)")
                }
            } else if let apSchema = schema["additionalProperties"] as? [String: Any] {
                for key in obj.keys where !known.contains(key) {
                    check(obj[key]!, against: apSchema, at: "\(path)/\(key)", into: &errs)
                }
            }
        }

        // array constraints
        if let arr = asArray(value) {
            if let items = schema["items"] as? [String: Any] {
                for (i, el) in arr.enumerated() {
                    check(el, against: items, at: "\(path)/\(i)", into: &errs)
                }
            } else if let tuple = schema["items"] as? [[String: Any]] {
                for (i, sub) in tuple.enumerated() where i < arr.count {
                    check(arr[i], against: sub, at: "\(path)/\(i)", into: &errs)
                }
            }
        }
    }

    /// Evaluate a combinator member that may be an object schema or a boolean
    /// schema (`true` ⇒ always valid, `false` ⇒ never valid).
    private static func subschemaValid(_ value: Any, _ sub: Any) -> Bool {
        if let b = sub as? Bool { return b }
        guard let obj = sub as? [String: Any] else { return true }  // unknown form → permissive
        var e: [String] = []
        check(value, against: obj, at: "root", into: &e)
        return e.isEmpty
    }

    // MARK: - type predicates

    private static func typeMatches(_ value: Any, _ type: String) -> Bool {
        switch type {
        case "object":  return asObject(value) != nil
        case "array":   return asArray(value) != nil
        case "string":  return value is String || value is NSString
        case "boolean": return isBoolNumber(value)
        case "null":    return value is NSNull
        case "integer":
            guard let n = value as? NSNumber, !isBoolNumber(value) else { return false }
            let d = n.doubleValue
            return d.rounded(.towardZero) == d && d.isFinite
        case "number":
            return (value as? NSNumber) != nil && !isBoolNumber(value)
        default:
            return true   // unknown type keyword → don't fail
        }
    }

    // MARK: - helpers

    private static func parse(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }
    private static func asObject(_ v: Any) -> [String: Any]? {
        // NSNull / NSNumber must not be coerced to a dictionary.
        if v is NSNull || v is NSNumber || v is String { return nil }
        return v as? [String: Any]
    }
    private static func asArray(_ v: Any) -> [Any]? {
        if v is String { return nil }
        return v as? [Any]
    }
    /// JSONSerialization bridges JSON booleans to `NSNumber` backed by
    /// `CFBoolean`; this is the only reliable way to tell `true` from `1`.
    private static func isBoolNumber(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    private static func jsonTypeName(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if isBoolNumber(v) { return "boolean" }
        if v is NSNumber { return "number" }
        if v is String || v is NSString { return "string" }
        if asArray(v) != nil { return "array" }
        if asObject(v) != nil { return "object" }
        return "unknown"
    }
    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull && b is NSNull { return true }
        if isBoolNumber(a) || isBoolNumber(b) {
            guard isBoolNumber(a), isBoolNumber(b) else { return false }
            return (a as! NSNumber).boolValue == (b as! NSNumber).boolValue
        }
        if let na = a as? NSNumber, let nb = b as? NSNumber { return na == nb }
        if let sa = a as? String, let sb = b as? String { return sa == sb }
        if let aa = asArray(a), let ab = asArray(b) {
            return aa.count == ab.count && zip(aa, ab).allSatisfy { jsonEqual($0, $1) }
        }
        if let oa = asObject(a), let ob = asObject(b) {
            return oa.keys.sorted() == ob.keys.sorted()
                && oa.allSatisfy { k, v in ob[k].map { jsonEqual(v, $0) } ?? false }
        }
        return false
    }
}
