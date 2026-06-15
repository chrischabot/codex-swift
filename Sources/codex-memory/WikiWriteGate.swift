import Foundation
import MemoryStore

/// Pre-commit validation gate that finally wires `WikiLinkLinter.lint()` into the
/// write path (gbrain.md Wave 0.2). Today `WikiLinkLinter.lint()` has zero
/// production callsites — broken links / ungrounded synthesis pages / non-reciprocal
/// see-also are detected by tests only. This gate runs the linter when a page is
/// about to be written.
///
/// Modes mirror gbrain's BrainWriter `StrictMode`:
/// - `.off`    — skip validation entirely.
/// - `.lint`   — validate, surface issues (append to a JSONL), always proceed.
///   **Default** — the soak posture before flipping to strict.
/// - `.strict` — validate; an error-severity issue (ungrounded / broken link)
///   reports `block = true` so the caller refuses the write.
///
/// (Strict-mode transactional ROLLBACK of an already-written page needs a
/// `MemoryStore` transaction primitive that spans the synthesis+claim+evidence+
/// link quadruple; that surgery is deferred. The gate's decision + logging are
/// the wired, tested piece. Callers should validate BEFORE writing where they
/// can, or treat `block` as "do not finalize".)
struct WikiWriteGate: Sendable {
    enum Mode: String, Sendable, CaseIterable { case off, lint, strict }

    let mode: Mode
    let vaultRoot: String

    init(mode: Mode, vaultRoot: String) {
        self.mode = mode
        self.vaultRoot = vaultRoot
    }

    /// Resolve the active mode: env `CODEXKIT_WIKI_LINT_ON_WRITE` wins, then the
    /// `wiki.lint_on_write` store meta key, else `.lint`.
    static func resolveMode(store: MemoryStore) async -> Mode {
        if let raw = ProcessInfo.processInfo.environment["CODEXKIT_WIKI_LINT_ON_WRITE"],
           let m = Mode(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) {
            return m
        }
        if let raw = (try? await store.metaValue("wiki.lint_on_write")) ?? nil,
           let m = Mode(rawValue: raw) {
            return m
        }
        return .lint
    }

    /// Which issue kinds block a write in strict mode. Non-reciprocal see-also is
    /// a warning (never a block); ungrounded + broken links are errors.
    static func isBlocking(_ issue: WikiLinkIssue) -> Bool {
        switch issue.kind {
        case .ungrounded, .brokenLink: return true
        case .nonReciprocalSeeAlso:    return false
        }
    }

    struct Verdict: Sendable, Equatable {
        var issues: [WikiLinkIssue]
        var block: Bool
    }

    /// Validate one page. `.off` → empty/no-block. Otherwise run the linter; both
    /// `.lint` and `.strict` append findings to `research/wiki-write-lint.jsonl`;
    /// only `.strict` sets `block` when an error-severity issue is present.
    func validate(_ page: WikiLintPage, validSlugs: Set<String>) -> Verdict {
        guard mode != .off else { return Verdict(issues: [], block: false) }
        let issues = WikiLinkLinter.lint([page], validSlugs: validSlugs)
        guard !issues.isEmpty else { return Verdict(issues: [], block: false) }
        for issue in issues {
            // Build the row WITHOUT `issue.target as Any` — an Optional inside the
            // dict makes JSONSerialization reject the whole object, so the JSONL line
            // would silently never be written (hiding exactly the ungrounded issues
            // this gate exists to surface).
            var obj: [String: Any] = ["page": issue.page, "kind": issue.kind.rawValue,
                                      "mode": mode.rawValue]
            if let target = issue.target { obj["target"] = target }
            ClaimWritePolicy.appendJSONL(
                path: vaultRoot + "/research/wiki-write-lint.jsonl", obj: obj)
        }
        let block = mode == .strict && issues.contains(where: Self.isBlocking)
        return Verdict(issues: issues, block: block)
    }
}
