import Foundation
import Mem0Core
import PostgresNIO

/// A small accumulator that builds a `PostgresQuery` with positional `$n` binds.
/// Every dynamic VALUE goes through `param(...)` (→ a real bind), and every
/// dynamic KEY is also bound (as a text value passed to the `->`/`->>`/`jsonb_*`
/// operators), so there is NO string-concatenated user data anywhere — the SQL
/// skeleton is fully static and injection-proof.
struct PGQueryBuilder {
    private(set) var sql: String = ""
    private(set) var binds = PostgresBindings()

    init() {}

    /// Append static SQL text (NEVER user-controlled).
    mutating func raw(_ text: String) { sql += text }

    /// Append a bound value and its `$n` placeholder.
    mutating func param<V: PostgresThrowingDynamicTypeEncodable>(_ value: V) throws {
        try binds.append(value)
        sql += "$\(binds.count)"
    }

    /// Append a bound OPTIONAL value (`nil` → SQL NULL) and its `$n` placeholder.
    mutating func paramOptional<V: PostgresThrowingDynamicTypeEncodable>(_ value: V?) throws {
        try binds.append(value)   // resolves to append(_:Optional<Value>) → NULL when nil
        sql += "$\(binds.count)"
    }

    func build() -> PostgresQuery { PostgresQuery(unsafeSQL: sql, binds: binds) }
}

/// Translates the `Mem0Filters` grammar (eq/ne/gt/gte/lt/lte/in/nin/contains/
/// icontains + `$or`/`$not` + the `"*"` wildcard + plain scalar equality, with
/// JSON-null values skipped) into a fully-parameterized SQL predicate over a
/// `jsonb payload` column. Mirrors `Mem0Filters.matchesFilters` /
/// `matchesCondition` / `evalOp` semantics as closely as JSONB allows.
///
/// Known, documented divergences vs the in-Swift matcher (all benign for mem0's
/// string-scoped filters):
///   • JSONB numeric equality treats `5` and `5.0` as equal; Swift's `JSONValue`
///     equality treats `.int(5)` and `.double(5.0)` as distinct.
///   • Numeric range ops accept integer/decimal text; Swift's `Double(_:)` also
///     parses scientific notation. The regex guard here is decimal-only.
enum PGFilterTranslator {
    /// Cheap pure check: will `appendPredicate` emit anything? Mirrors the skip
    /// logic (a key is `$or`/`$not`, or any value is non-null). Lets the caller
    /// decide whether to write `" WHERE "` before appending (the builder is
    /// append-only, so we can't retract a dangling `WHERE`).
    static func willEmit(_ filters: JSONObject) -> Bool {
        for (k, v) in filters {
            if k == "$or" || k == "$not" { return true }
            if !v.isNull { return true }
        }
        return false
    }

    /// Append the WHERE predicate for `filters` (without the `WHERE` keyword).
    /// Returns `true` if any predicate was emitted (caller prefixes `" WHERE "`),
    /// `false` if the filter set is empty / all-null (caller omits the clause).
    @discardableResult
    static func appendPredicate(_ filters: JSONObject, into b: inout PGQueryBuilder) throws -> Bool {
        var emittedAny = false
        for (key, cond) in filters {
            switch key {
            case "$or":
                if emittedAny { b.raw(" AND ") }
                try appendOrGroup(cond.arrayValue ?? [], negate: false, into: &b)
                emittedAny = true
            case "$not":
                if emittedAny { b.raw(" AND ") }
                try appendOrGroup(cond.arrayValue ?? [], negate: true, into: &b)
                emittedAny = true
            default:
                if cond.isNull { continue }   // null value → skipped, exactly like Swift
                if emittedAny { b.raw(" AND ") }
                try appendKeyCondition(key, cond, into: &b)
                emittedAny = true
            }
        }
        return emittedAny
    }

    // `$or` (negate=false) → (c1 OR c2 …) ; `$not` (negate=true) → NOT COALESCE((c1 OR c2 …), false)
    //
    // The COALESCE on the negated branch is load-bearing: Mem0Filters' `$not`
    // includes a record iff NONE of the conditions MATCH (a clean Bool — an absent
    // key is "not a match", i.e. false). In SQL, a condition over an absent key is
    // NULL, and `NOT NULL` is NULL (→ row excluded), which would WRONGLY drop
    // records that Swift keeps. Coercing the group's NULL → false before negating
    // restores 2-valued "matched?" semantics so `NOT false = true` includes them.
    // (`$or` needs no such coercion: an all-NULL/false group is NULL, and a plain
    // WHERE drops NULL rows — exactly Swift's "no condition matched → excluded".)
    private static func appendOrGroup(_ conditions: [JSONValue], negate: Bool,
                                      into b: inout PGQueryBuilder) throws {
        if conditions.isEmpty {
            // Mem0Filters requires a non-empty list, but be defensive: empty $or
            // matches nothing; empty $not matches everything.
            b.raw(negate ? "true" : "false")
            return
        }
        b.raw(negate ? "NOT COALESCE((" : "(")
        for (i, sub) in conditions.enumerated() {
            if i > 0 { b.raw(" OR ") }
            b.raw("(")
            if let obj = sub.objectValue {
                // an empty / all-null object matches everything (Mem0Filters:
                // matchesFilters(payload, {}) == true), so emit `true` then.
                let emitted = try appendPredicate(obj, into: &b)
                if !emitted { b.raw("true") }
            } else {
                // a NON-object child never matches in the reference matcher
                // (Filters.swift: `(f.objectValue).map { … } ?? false`) — emit
                // `false`, not `true`, or $or would match-all and $not exclude-all.
                b.raw("false")
            }
            b.raw(")")
        }
        b.raw(negate ? "), false)" : ")")
    }

    // One `key: condition` pair (condition is an op-object, the "*" wildcard, or a
    // scalar equality value).
    private static func appendKeyCondition(_ key: String, _ cond: JSONValue,
                                           into b: inout PGQueryBuilder) throws {
        switch cond {
        case .object(let ops):
            if ops.isEmpty { b.raw("true"); return }   // allSatisfy over ∅ == true
            b.raw("(")
            var first = true
            for (op, val) in ops {
                if !first { b.raw(" AND ") }
                first = false
                try appendOp(key, op, val, into: &b)
            }
            b.raw(")")
        case .string(let s) where s == "*":
            // wildcard: key present AND value not JSON null
            b.raw("(jsonb_exists(payload, ")
            try b.param(key)
            b.raw(") AND payload -> ")
            try b.param(key)
            b.raw(" <> 'null'::jsonb)")
        default:
            // plain scalar equality: payload->key = value::jsonb
            b.raw("(payload -> ")
            try b.param(key)
            b.raw(" = ")
            try b.param(cond.jsonString())
            b.raw("::jsonb)")
        }
    }

    private static func appendOp(_ key: String, _ op: String, _ val: JSONValue,
                                 into b: inout PGQueryBuilder) throws {
        switch op {
        case "eq":
            b.raw("(payload -> "); try b.param(key); b.raw(" = "); try b.param(val.jsonString()); b.raw("::jsonb)")
        case "ne":
            b.raw("(payload -> "); try b.param(key); b.raw(" IS DISTINCT FROM "); try b.param(val.jsonString()); b.raw("::jsonb)")
        case "in":
            let arr = val.arrayValue ?? []
            if arr.isEmpty { b.raw("false"); return }
            b.raw("(")
            for (i, el) in arr.enumerated() {
                if i > 0 { b.raw(" OR ") }
                b.raw("payload -> "); try b.param(key); b.raw(" = "); try b.param(el.jsonString()); b.raw("::jsonb")
            }
            b.raw(")")
        case "nin":
            let arr = val.arrayValue ?? []
            if arr.isEmpty { b.raw("true"); return }   // !contains over ∅ == true
            b.raw("(")
            for (i, el) in arr.enumerated() {
                if i > 0 { b.raw(" AND ") }
                b.raw("payload -> "); try b.param(key); b.raw(" IS DISTINCT FROM "); try b.param(el.jsonString()); b.raw("::jsonb")
            }
            b.raw(")")
        case "gt", "gte", "lt", "lte":
            let sqlOp = ["gt": ">", "gte": ">=", "lt": "<", "lte": "<="][op]!
            guard let num = val.doubleValue else { b.raw("false"); return }
            b.raw("(")
            try appendNumericExtract(key, into: &b)
            b.raw(" \(sqlOp) ")
            try b.param(num)
            b.raw(")")
        case "contains":
            guard let s = val.stringValue else { b.raw("false"); return }
            b.raw("(jsonb_typeof(payload -> "); try b.param(key)
            b.raw(") = 'string' AND strpos(payload ->> "); try b.param(key)
            b.raw(", "); try b.param(s); b.raw(") > 0)")
        case "icontains":
            guard let s = val.stringValue else { b.raw("false"); return }
            b.raw("(jsonb_typeof(payload -> "); try b.param(key)
            b.raw(") = 'string' AND strpos(lower(payload ->> "); try b.param(key)
            b.raw("), lower("); try b.param(s); b.raw(")) > 0)")
        default:
            // Unknown operator (Mem0Filters validates these upstream) → never true.
            b.raw("false")
        }
    }

    // CASE that yields a double from a numeric jsonb value, or a decimal-looking
    // string — else NULL (→ comparison not true, matching Swift's `false`).
    private static func appendNumericExtract(_ key: String, into b: inout PGQueryBuilder) throws {
        b.raw("(CASE WHEN jsonb_typeof(payload -> "); try b.param(key)
        b.raw(") = 'number' THEN (payload ->> "); try b.param(key)
        b.raw(")::double precision WHEN jsonb_typeof(payload -> "); try b.param(key)
        b.raw(") = 'string' AND (payload ->> "); try b.param(key)
        // Decimal + scientific notation, mirroring Swift's Double(_:) for the
        // common cases. (Swift also parses +5/.5/5./0x10; those rare forms remain
        // a documented divergence — see docs/MEM0_POSTGRES.md.)
        b.raw(") ~ '^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$' THEN (payload ->> "); try b.param(key)
        b.raw(")::double precision END)")
    }
}
