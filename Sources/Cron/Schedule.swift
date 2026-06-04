import Foundation

// ADDONS.md #6 — the cron/scheduler primitive. Supervisor-resident scheduled
// jobs that fire a prompt (and deliver via push #7). This file is the schedule
// model + next-fire computation (pure + testable).
//
// EXPLICIT DST POLICY: cron expressions run in **UTC**. A hand-rolled local-time
// cron is a DST-correctness minefield (skipped/duplicated hours); pinning to UTC
// makes every fire unambiguous. `at`/`every` are wall-clock-independent already.

public enum Schedule: Sendable, Equatable, Codable {
    /// One-shot at an absolute epoch second.
    case at(Int64)
    /// Repeat every N seconds (anchored on the last run).
    case every(Int64)
    /// 5-field cron `"min hour dom month dow"` in UTC (`*`, `N`, `A-B`, `*/S`,
    /// `A-B/S`, comma lists; dow 0/7 = Sunday).
    case cron(String)

    /// The first fire strictly AFTER `t` (epoch seconds), or nil (a past one-shot
    /// / unparseable cron / no match within the search horizon).
    public func next(after t: Int64) -> Int64? {
        switch self {
        case .at(let when):
            return when > t ? when : nil
        case .every(let n):
            guard n > 0 else { return nil }
            return t + n
        case .cron(let expr):
            return CronExpr.next(expr, after: t)
        }
    }
}

/// A parsed 5-field UTC cron expression.
enum CronExpr {
    static func next(_ expr: String, after t: Int64) -> Int64? {
        let fields = expr.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5,
              let minute = parseField(fields[0], min: 0, max: 59),
              let hour = parseField(fields[1], min: 0, max: 23),
              let dom = parseField(fields[2], min: 1, max: 31),
              let month = parseField(fields[3], min: 1, max: 12),
              var dow = parseField(fields[4], min: 0, max: 7) else { return nil }
        // Normalize dow 7 → 0 (both are Sunday).
        if dow.contains(7) { dow.remove(7); dow.insert(0) }
        let domRestricted = fields[2] != "*"
        let dowRestricted = fields[4] != "*"

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // Start at the next whole minute after t; scan up to a 4-year horizon.
        var cur = ((t / 60) + 1) * 60
        let limit = t + 4 * 366 * 24 * 3600
        while cur <= limit {
            let date = Date(timeIntervalSince1970: Double(cur))
            let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
            guard let mi = c.minute, let h = c.hour, let d = c.day, let mo = c.month, let wd = c.weekday else {
                cur += 60; continue
            }
            let cronWeekday = wd - 1   // Calendar: 1=Sun..7=Sat → cron 0=Sun..6=Sat
            let dayMatch: Bool
            if domRestricted && dowRestricted { dayMatch = dom.contains(d) || dow.contains(cronWeekday) }
            else if domRestricted { dayMatch = dom.contains(d) }
            else if dowRestricted { dayMatch = dow.contains(cronWeekday) }
            else { dayMatch = true }
            if minute.contains(mi) && hour.contains(h) && month.contains(mo) && dayMatch {
                return cur
            }
            cur += 60
        }
        return nil
    }

    /// Parse one field into the set of matching values over `[min, max]`.
    static func parseField(_ field: String, min: Int, max: Int) -> Set<Int>? {
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            var rangeStr = Substring(part)
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                rangeStr = part[part.startIndex..<slash]
                guard let s = Int(part[part.index(after: slash)...]), s > 0 else { return nil }
                step = s
            }
            let lo: Int, hi: Int
            if rangeStr == "*" {
                lo = min; hi = max
            } else if let dash = rangeStr.firstIndex(of: "-") {
                guard let a = Int(rangeStr[rangeStr.startIndex..<dash]),
                      let b = Int(rangeStr[rangeStr.index(after: dash)...]) else { return nil }
                lo = a; hi = b
            } else {
                guard let v = Int(rangeStr) else { return nil }
                lo = v; hi = v
            }
            guard lo >= min, hi <= max, lo <= hi else { return nil }
            var v = lo
            while v <= hi { result.insert(v); v += step }
        }
        return result.isEmpty ? nil : result
    }
}
