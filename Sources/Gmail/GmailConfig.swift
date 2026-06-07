import Foundation

/// Pure resolver for `[channels.gmail]` (mirrors `TelegramConfig.load`): the
/// composition root extracts the raw config values and passes them here, so the
/// deny-default gate + owner normalization are unit-testable without importing
/// `Config` into the `Gmail` target. The Google OAuth credentials come from
/// `[connectors.google]` (the SAME connected account the `google_api` tool uses) —
/// this struct carries only the channel-specific knobs.
///
/// SCOPE NOTE: the Gmail channel needs `gmail.modify` granted on the connected
/// Google account — to mark inbound mail read (so it isn't reprocessed) and to
/// send replies. The connector defaults are read-only (least privilege), so an
/// operator enabling this channel must add `gmail.modify` to
/// `[connectors.google].scopes` and re-run `codexd google-connect`. Without it,
/// reads still work but mark-read + send fail (gracefully, logged) and the
/// channel falls back to its in-memory de-dup to avoid reprocessing.
public struct GmailConfig: Sendable, Equatable {
    /// Lowercased, de-duplicated owner email allowlist. EMPTY ⇒ every sender is
    /// NON-OWNER (read-only, locked-down turns) — the safe default.
    public let ownerEmails: [String]
    /// Optional From address for sends (nil ⇒ the account's own address).
    public let fromAddress: String?
    public let pollMs: Int

    public init(ownerEmails: [String], fromAddress: String?, pollMs: Int) {
        self.ownerEmails = ownerEmails
        self.fromAddress = fromAddress
        self.pollMs = pollMs
    }

    /// nil when the channel is disabled (deny-default). `pollMs` is clamped to a
    /// 2s floor so a misconfig can't hammer the Gmail API.
    public static func load(enabled: Bool,
                            ownerEmails: [String] = [],
                            fromAddress: String? = nil,
                            pollMs: Int? = nil) -> GmailConfig? {
        guard enabled else { return nil }
        let emails = Set(ownerEmails
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        let from = (fromAddress?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        return GmailConfig(ownerEmails: emails.sorted(),
                           fromAddress: from,
                           pollMs: Swift.max(2_000, pollMs ?? 15_000))
    }
}
