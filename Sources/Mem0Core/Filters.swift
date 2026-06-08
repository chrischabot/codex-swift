import Foundation

/// Filter / metadata construction and evaluation, ported from
/// `mem0-rs/crates/mem0-core/src/filters.rs` (mem0's `_build_filters_and_metadata`,
/// `_build_session_scope`, `_has_advanced_operators`, `_process_metadata_filters`,
/// validators, and the operator matcher).
public enum Mem0Filters {
    static let operators: Set<String> = [
        "eq", "ne", "gt", "gte", "lt", "lte", "in", "nin", "contains", "icontains",
    ]

    /// Validate and trim an optional entity id. Port of `validate_and_trim_entity_id`.
    public static func validateAndTrimEntityID(_ value: String?, _ name: String) throws -> String? {
        guard let v = value else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            throw Mem0Error.validationCode(
                "VALIDATION_003",
                "'\(name)' must be a non-empty string when provided.",
                "Provide a non-empty value for '\(name)' or omit it.")
        }
        return trimmed
    }

    /// Validate search parameters. Port of `validate_search_params`.
    public static func validateSearchParams(threshold: Double?, topK: Int?) throws {
        if let t = topK {
            if t <= 0 {
                throw Mem0Error.validationCode("VALIDATION_004", "top_k must be a positive integer.",
                                               "Pass a top_k greater than 0.")
            }
            if t > 1_000 {
                throw Mem0Error.validationCode("VALIDATION_004", "top_k must be <= 1000.",
                                               "Pass a smaller top_k.")
            }
        }
        if let th = threshold, th < 0.0 || th > 1.0 {
            throw Mem0Error.validationCode("VALIDATION_005", "threshold must be between 0.0 and 1.0.",
                                           "Pass a threshold in the [0.0, 1.0] range.")
        }
    }

    /// Build `(baseMetadata, effectiveFilters)`. Port of `build_filters_and_metadata`.
    public static func buildFiltersAndMetadata(userID: String?, agentID: String?, runID: String?,
                                               actorID: String? = nil,
                                               inputMetadata: JSONObject? = nil,
                                               inputFilters: JSONObject? = nil) throws -> (JSONObject, JSONObject) {
        var base = inputMetadata ?? [:]
        var filters = inputFilters ?? [:]

        let u = try validateAndTrimEntityID(userID, "user_id")
        let a = try validateAndTrimEntityID(agentID, "agent_id")
        let r = try validateAndTrimEntityID(runID, "run_id")

        var provided = false
        if let u { base["user_id"] = .string(u); filters["user_id"] = .string(u); provided = true }
        if let a { base["agent_id"] = .string(a); filters["agent_id"] = .string(a); provided = true }
        if let r { base["run_id"] = .string(r); filters["run_id"] = .string(r); provided = true }

        if !provided {
            throw Mem0Error.validationCode(
                "VALIDATION_001",
                "At least one of 'user_id', 'agent_id', or 'run_id' must be provided.",
                "Please provide at least one identifier to scope the memory operation.")
        }

        let resolvedActor = actorID ?? filters["actor_id"]?.stringValue
        if let act = resolvedActor { filters["actor_id"] = .string(act) }

        return (base, filters)
    }

    /// Deterministic session-scope key from entity ids (sorted key order).
    /// Port of `build_session_scope`.
    public static func buildSessionScope(_ filters: JSONObject) -> String {
        var parts: [String] = []
        for key in ["agent_id", "run_id", "user_id"] {
            if let v = filters[key]?.stringValue, !v.isEmpty {
                parts.append("\(key)=\(v)")
            }
        }
        return parts.joined(separator: "&")
    }

    /// Extract only the session-scoping ids. Port of `session_filters`.
    public static func sessionFilters(_ filters: JSONObject) -> JSONObject {
        var out: JSONObject = [:]
        for key in ["user_id", "agent_id", "run_id"] {
            if let v = filters[key], let s = v.stringValue, !s.isEmpty { out[key] = v }
        }
        return out
    }

    /// Whether filters contain advanced operators. Port of `has_advanced_operators`.
    public static func hasAdvancedOperators(_ filters: JSONObject) -> Bool {
        for (key, value) in filters {
            if key == "AND" || key == "OR" || key == "NOT" { return true }
            if let obj = value.objectValue {
                for op in obj.keys where operators.contains(op) { return true }
            }
            if value.stringValue == "*" { return true }
        }
        return false
    }

    private static func processCondition(_ key: String, _ condition: JSONValue) throws -> JSONObject {
        var result: JSONObject = [:]
        switch condition {
        case .object(let map):
            var opmap: JSONObject = [:]
            for (op, val) in map {
                if operators.contains(op) { opmap[op] = val }
                else { throw Mem0Error.validation("Unsupported metadata filter operator: \(op)") }
            }
            result[key] = .object(opmap)
        case .string(let s) where s == "*":
            result[key] = .string("*")
        default:
            result[key] = condition
        }
        return result
    }

    private static func mergeFilters(_ target: inout JSONObject, _ source: JSONObject) {
        for (k, v) in source {
            if case .object(let tv)? = target[k], case .object(let sv) = v {
                var merged = tv
                for (kk, vv) in sv { merged[kk] = vv }
                target[k] = .object(merged)
            } else {
                target[k] = v
            }
        }
    }

    /// Normalize advanced filters into store-compatible form. Port of
    /// `process_metadata_filters` (AND flattened, OR → `$or`, NOT → `$not`).
    public static func processMetadataFilters(_ metadataFilters: JSONObject) throws -> JSONObject {
        var processed: JSONObject = [:]
        for (key, value) in metadataFilters {
            switch key {
            case "AND":
                guard let arr = value.arrayValue else {
                    throw Mem0Error.validation("AND operator requires a list of conditions")
                }
                for condition in arr {
                    if let obj = condition.objectValue {
                        for (sk, sv) in obj {
                            let pc = try processCondition(sk, sv)
                            mergeFilters(&processed, pc)
                        }
                    }
                }
            case "OR":
                guard let arr = value.arrayValue, !arr.isEmpty else {
                    throw Mem0Error.validation("OR operator requires a non-empty list of conditions")
                }
                var orList: [JSONValue] = []
                for condition in arr {
                    var orCond: JSONObject = [:]
                    if let obj = condition.objectValue {
                        for (sk, sv) in obj {
                            let pc = try processCondition(sk, sv)
                            mergeFilters(&orCond, pc)
                        }
                    }
                    orList.append(.object(orCond))
                }
                processed["$or"] = .array(orList)
            case "NOT":
                guard let arr = value.arrayValue, !arr.isEmpty else {
                    throw Mem0Error.validation("NOT operator requires a non-empty list of conditions")
                }
                var notList: [JSONValue] = []
                for condition in arr {
                    var notCond: JSONObject = [:]
                    if let obj = condition.objectValue {
                        for (sk, sv) in obj {
                            let pc = try processCondition(sk, sv)
                            mergeFilters(&notCond, pc)
                        }
                    }
                    notList.append(.object(notCond))
                }
                processed["$not"] = .array(notList)
            default:
                let pc = try processCondition(key, value)
                mergeFilters(&processed, pc)
            }
        }
        return processed
    }

    /// Evaluate whether a payload satisfies (possibly operator-laden) filters.
    /// Port of `matches_filters` (+ `$or`/`$not`, wildcard, null skip).
    public static func matchesFilters(_ payload: JSONObject, _ filters: JSONObject) -> Bool {
        for (key, cond) in filters {
            switch key {
            case "$or":
                let ok = (cond.arrayValue ?? []).contains { f in
                    (f.objectValue).map { matchesFilters(payload, $0) } ?? false
                }
                if !ok { return false }
            case "$not":
                let any = (cond.arrayValue ?? []).contains { f in
                    (f.objectValue).map { matchesFilters(payload, $0) } ?? false
                }
                if any { return false }
            default:
                if cond.isNull { continue }
                if !matchesCondition(payload[key], cond) { return false }
            }
        }
        return true
    }

    private static func matchesCondition(_ pv: JSONValue?, _ cond: JSONValue) -> Bool {
        switch cond {
        case .object(let ops):
            return ops.allSatisfy { evalOp(pv, $0.key, $0.value) }
        case .string(let s) where s == "*":
            return pv != nil && !(pv?.isNull ?? true)
        default:
            return pv == cond
        }
    }

    private static func evalOp(_ pv: JSONValue?, _ op: String, _ val: JSONValue) -> Bool {
        switch op {
        case "eq": return pv == val
        case "ne": return pv != val
        case "in": return (val.arrayValue?.contains { $0 == pv }) ?? false
        case "nin": return !((val.arrayValue?.contains { $0 == pv }) ?? false)
        case "gt", "gte", "lt", "lte":
            guard let a = pv?.doubleValue, let b = val.doubleValue else { return false }
            switch op {
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            default: return a <= b
            }
        case "contains":
            guard let a = pv?.stringValue, let b = val.stringValue else { return false }
            return a.contains(b)
        case "icontains":
            guard let a = pv?.stringValue, let b = val.stringValue else { return false }
            return a.lowercased().contains(b.lowercased())
        default:
            return false
        }
    }
}
