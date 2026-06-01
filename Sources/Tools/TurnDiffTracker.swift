import Foundation
import CryptoKit
import ProtocolModel

// Faithful port of codex-rs `core/src/turn_diff_tracker.rs`.
//
// Tracks the net text diff for the current turn from committed apply_patch
// mutations, without rereading the workspace filesystem. The accumulated
// state is rendered into a single Git-format unified diff string that the
// engine emits as the `turn/diff/updated` notification.

private let zeroOID = "0000000000000000000000000000000000000000"
private let devNull = "/dev/null"
private let regularFileMode = "100644"

/// Port of `codex_apply_patch::AppliedPatchFileChange` (apply-patch/src/lib.rs).
/// The textual content actually committed while applying a single file change.
public enum AppliedPatchFileChange: Sendable, Equatable, Codable {
    /// New file (or overwrite of an existing file, in which case
    /// `overwrittenContent` carries the prior on-disk text).
    case add(content: String, overwrittenContent: String?)
    /// Deleted file; `content` is the text that existed before removal.
    case delete(content: String)
    /// In-place edit, optionally moved to `movePath`. `overwrittenMoveContent`
    /// carries the destination's prior text when the move overwrites an
    /// existing file.
    case update(movePath: String?, oldContent: String,
                overwrittenMoveContent: String?, newContent: String)
}

/// Port of `codex_apply_patch::AppliedPatchChange`.
public struct AppliedPatchChange: Sendable, Equatable, Codable {
    public var path: String
    public var change: AppliedPatchFileChange
    public init(path: String, change: AppliedPatchFileChange) {
        self.path = path
        self.change = change
    }
}

/// Port of `codex_apply_patch::AppliedPatchDelta`: the ordered list of textual
/// file changes that were actually committed while applying a patch, plus the
/// `exact` flag (false when the applier had to fall back to fuzzy matching, in
/// which case the tracked content can no longer be trusted as a faithful diff).
public struct AppliedPatchDelta: Sendable, Equatable, Codable {
    public private(set) var changes: [AppliedPatchChange]
    public private(set) var exact: Bool
    public init(changes: [AppliedPatchChange], exact: Bool = true) {
        self.changes = changes
        self.exact = exact
    }
    public static func empty() -> AppliedPatchDelta { AppliedPatchDelta(changes: [], exact: true) }
    public var isEmpty: Bool { changes.isEmpty }
    public var isExact: Bool { exact }
    /// Appends a later committed prefix while preserving aggregate exactness.
    public mutating func append(_ other: AppliedPatchDelta) {
        changes.append(contentsOf: other.changes)
        exact = exact && other.exact
    }

    /// Convert this committed delta into the upstream `Vec<FileUpdateChange>`
    /// shape carried by the `fileChange` ThreadItem and the
    /// `item/fileChange/patchUpdated` notification. Mirrors
    /// `app-server-protocol::item_builders::convert_patch_changes` +
    /// `format_file_change_diff` (item_builders.rs:279-318): per-file
    /// `{path, kind, diff}` where `diff` is the raw content for Add/Delete and
    /// the unified diff for Update (with a trailing `"\n\nMoved to: {path}"`
    /// when the update renamed the file), and the result is sorted by path.
    public func toFileUpdateChanges() -> [ThreadItem.FileChange] {
        var converted: [ThreadItem.FileChange] = changes.map { change in
            switch change.change {
            case let .add(content, _):
                return ThreadItem.FileChange(path: change.path, kind: .add, diff: content)
            case let .delete(content):
                return ThreadItem.FileChange(path: change.path, kind: .delete, diff: content)
            case let .update(movePath, oldContent, _, newContent):
                // Upstream computes the per-file Update unified diff via
                // `unified_diff_from_chunks` → `unified_diff_from_chunks_with_context(..., 1, ...)`
                // (apply-patch/src/lib.rs:820-841), i.e. similar's `context_radius(1)`.
                // `format_file_change_diff` (item_builders.rs:302-315) copies that diff
                // verbatim into `FileUpdateChange.diff`, so the fileChange thread item /
                // `item/fileChange/patchUpdated` payload must use context 1 — NOT the
                // similar DEFAULT of 3 used by the separate `turn/diff/updated` Git diff
                // (`TurnDiffTracker.unifiedDiff`).
                let unified = ApplyPatch.makeUnifiedDiff(
                    old: oldContent, new: newContent, path: change.path,
                    movePath: movePath, kind: .update, context: 1)
                let diff: String
                if let movePath {
                    diff = "\(unified)\n\nMoved to: \(movePath)"
                } else {
                    diff = unified
                }
                return ThreadItem.FileChange(
                    path: change.path, kind: .update(movePath: movePath), diff: diff)
            }
        }
        converted.sort { $0.path < $1.path }
        return converted
    }
}

/// Faithful port of `TurnDiffTracker`.
public struct TurnDiffTracker: Sendable {
    private var valid: Bool = true
    private var displayRoot: String?
    private var baselineByPath: [String: String] = [:]
    private var currentByPath: [String: String] = [:]
    private var originByCurrentPath: [String: String] = [:]

    public init() {}

    public static func withDisplayRoot(_ displayRoot: String) -> TurnDiffTracker {
        var t = TurnDiffTracker()
        t.displayRoot = displayRoot
        return t
    }

    public mutating func trackDelta(_ delta: AppliedPatchDelta) {
        if !delta.isExact {
            invalidate()
            return
        }
        for change in delta.changes {
            applyChange(change)
        }
    }

    public mutating func invalidate() {
        valid = false
    }

    public func getUnifiedDiff() -> String? {
        if !valid { return nil }

        let renamePairs = self.renamePairs()
        let pairedDestinations = Set(renamePairs.values)
        var handled = Set<String>()

        // Union of baseline + current keys, deduped, sorted by display path.
        var paths = Array(Set(baselineByPath.keys).union(currentByPath.keys))
        paths.sort { displayPath($0) < displayPath($1) }

        var aggregated = ""
        for path in paths {
            if !handled.insert(path).inserted { continue }
            if pairedDestinations.contains(path) { continue }

            let diff: String?
            if let dest = renamePairs[path] {
                handled.insert(dest)
                diff = renderRenameDiff(source: path, dest: dest)
            } else {
                diff = renderPathDiff(path)
            }

            if let diff {
                aggregated += diff
                if !aggregated.hasSuffix("\n") { aggregated += "\n" }
            }
        }

        return aggregated.isEmpty ? nil : aggregated
    }

    // MARK: - State mutation (apply_change family)

    private mutating func applyChange(_ change: AppliedPatchChange) {
        let path = change.path
        switch change.change {
        case let .add(content, overwritten):
            applyAdd(path, content: content, overwritten: overwritten)
        case let .delete(content):
            applyDelete(path, content: content)
        case let .update(movePath, oldContent, overwrittenMove, newContent):
            applyUpdate(path, movePath: movePath, oldContent: oldContent,
                        overwrittenMoveContent: overwrittenMove, newContent: newContent)
        }
    }

    private mutating func applyAdd(_ path: String, content: String, overwritten: String?) {
        originByCurrentPath.removeValue(forKey: path)
        if currentByPath[path] == nil, baselineByPath[path] == nil,
           let overwritten {
            baselineByPath[path] = overwritten
        }
        currentByPath[path] = content
    }

    private mutating func applyDelete(_ path: String, content: String) {
        if currentByPath.removeValue(forKey: path) == nil, baselineByPath[path] == nil {
            baselineByPath[path] = content
        }
        originByCurrentPath.removeValue(forKey: path)
    }

    private mutating func applyUpdate(_ sourcePath: String, movePath: String?,
                                      oldContent: String,
                                      overwrittenMoveContent: String?,
                                      newContent: String) {
        if currentByPath[sourcePath] == nil, baselineByPath[sourcePath] == nil {
            baselineByPath[sourcePath] = oldContent
        }

        if let destPath = movePath {
            if currentByPath[destPath] == nil, baselineByPath[destPath] == nil,
               let overwrittenMoveContent {
                baselineByPath[destPath] = overwrittenMoveContent
            }
            let origin = originByCurrentPath.removeValue(forKey: sourcePath) ?? sourcePath
            currentByPath.removeValue(forKey: sourcePath)
            currentByPath[destPath] = newContent
            originByCurrentPath.removeValue(forKey: destPath)
            if destPath != origin {
                originByCurrentPath[destPath] = origin
            }
        } else {
            currentByPath[sourcePath] = newContent
        }
    }

    private func renamePairs() -> [String: String] {
        var result: [String: String] = [:]
        for (destPath, originPath) in originByCurrentPath {
            if destPath == originPath
                || currentByPath[originPath] != nil
                || currentByPath[destPath] == nil
                || baselineByPath[originPath] == nil
                || baselineByPath[destPath] != nil {
                continue
            }
            result[originPath] = destPath
        }
        return result
    }

    // MARK: - Rendering

    private func renderPathDiff(_ path: String) -> String? {
        renderDiff(leftPath: path, leftContent: baselineByPath[path],
                   rightPath: path, rightContent: currentByPath[path])
    }

    private func renderRenameDiff(source: String, dest: String) -> String? {
        renderDiff(leftPath: source, leftContent: baselineByPath[source],
                   rightPath: dest, rightContent: currentByPath[dest])
    }

    private func renderDiff(leftPath: String, leftContent: String?,
                            rightPath: String, rightContent: String?) -> String? {
        if leftContent == rightContent { return nil }

        let leftDisplay = displayPath(leftPath)
        let rightDisplay = displayPath(rightPath)
        let leftOID = leftContent.map { Self.gitBlobOID($0) } ?? zeroOID
        let rightOID = rightContent.map { Self.gitBlobOID($0) } ?? zeroOID

        var diff = "diff --git a/\(leftDisplay) b/\(rightDisplay)\n"
        switch (leftContent, rightContent) {
        case (nil, .some):
            diff += "new file mode \(regularFileMode)\n"
        case (.some, nil):
            diff += "deleted file mode \(regularFileMode)\n"
        case (.some, .some):
            break
        case (nil, nil):
            return nil
        }

        diff += "index \(leftOID)..\(rightOID)\n"

        let oldHeader = leftContent != nil ? "a/\(leftDisplay)" : devNull
        let newHeader = rightContent != nil ? "b/\(rightDisplay)" : devNull

        diff += Self.unifiedDiff(oldContent: leftContent ?? "",
                                 newContent: rightContent ?? "",
                                 oldHeader: oldHeader, newHeader: newHeader)
        return diff
    }

    private func displayPath(_ path: String) -> String {
        var display = path
        if let root = displayRoot {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path == root {
                display = ""
            } else if path.hasPrefix(prefix) {
                display = String(path.dropFirst(prefix.count))
            }
        }
        return display.replacingOccurrences(of: "\\", with: "/")
    }

    // MARK: - Git blob OID

    /// Git SHA-1 blob object ID for the given content: SHA1("blob <len>\0<bytes>").
    static func gitBlobOID(_ content: String) -> String {
        let bytes = Array(content.utf8)
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(bytes.count)\u{0}".utf8))
        h.update(data: Data(bytes))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Unified diff (parity with `similar::TextDiff` unified output)

    /// Splits content into lines the way `similar`'s line tokenizer does:
    /// a trailing newline does NOT produce a synthetic empty final line.
    private static func lines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private enum Op { case eq, del, ins }

    /// Produces the `--- old\n+++ new\n` header followed by unified hunks with
    /// context radius 3, matching `similar::TextDiff::from_lines(...).unified_diff()`.
    static func unifiedDiff(oldContent: String, newContent: String,
                            oldHeader: String, newHeader: String) -> String {
        let a = lines(oldContent)
        let b = lines(newContent)
        let ops = diffOps(a, b)
        if ops.allSatisfy({ $0.0 == .eq }) {
            // No textual change between contents — no hunks.
            return ""
        }

        let context = 3
        var out = "--- \(oldHeader)\n+++ \(newHeader)\n"

        // Group ops into hunks separated by >2*context unchanged lines.
        let n = ops.count
        var idx = 0
        while idx < n {
            while idx < n && ops[idx].0 == .eq { idx += 1 }
            if idx >= n { break }

            let changeStart = idx
            var j = idx
            var lastChange = idx
            while j < n {
                if ops[j].0 != .eq {
                    lastChange = j
                    j += 1
                } else {
                    var k = j
                    while k < n && ops[k].0 == .eq { k += 1 }
                    if k >= n { break }
                    if k - j > 2 * context { break }
                    j = k
                }
            }

            let s = Swift.max(0, changeStart - context)
            let e = Swift.min(n - 1, lastChange + context)

            var oCount = 0, nCount = 0
            for k in s...e {
                if ops[k].0 != .ins { oCount += 1 }
                if ops[k].0 != .del { nCount += 1 }
            }
            var preO = 0, preN = 0
            if s > 0 {
                for k in 0..<s {
                    if ops[k].0 != .ins { preO += 1 }
                    if ops[k].0 != .del { preN += 1 }
                }
            }
            let oStart = oCount > 0 ? preO + 1 : preO
            let nStart = nCount > 0 ? preN + 1 : preN

            out += "@@ -\(hunkRange(oStart, oCount)) +\(hunkRange(nStart, nCount)) @@\n"
            for k in s...e {
                let prefix: String
                switch ops[k].0 {
                case .eq: prefix = " "
                case .del: prefix = "-"
                case .ins: prefix = "+"
                }
                out += prefix + ops[k].1 + "\n"
            }
            idx = e + 1
        }
        return out
    }

    /// Git/similar hunk-range formatting: a single-line range omits the `,count`.
    private static func hunkRange(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }

    /// LCS line diff producing an ordered op list (parity with the line tokens
    /// `similar` emits for a unified diff).
    private static func diffOps(_ a: [String], _ b: [String]) -> [(Op, String)] {
        let n = a.count, m = b.count
        if n == 0 && m == 0 { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = Swift.max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }
        var out: [(Op, String)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                out.append((.eq, a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append((.del, a[i])); i += 1
            } else {
                out.append((.ins, b[j])); j += 1
            }
        }
        while i < n { out.append((.del, a[i])); i += 1 }
        while j < m { out.append((.ins, b[j])); j += 1 }
        return out
    }
}
