import Foundation
import WireProtocol

// Wire types for the June-2026 upstream sync (codex-rs dfd03ea01b). These mirror
// `app-server-protocol/src/protocol/v2/*` for the four newly-added client methods
// and three server notifications. See tools/catchup-backlog.md.

// MARK: thread/delete

/// `v2::ThreadDeleteParams` — `{ threadId }`.
public struct ThreadDeleteParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public init(threadId: ThreadId) { self.threadId = threadId }
}

// MARK: permissionProfile/list

/// `v2::PermissionProfileListParams` — all fields optional.
public struct PermissionProfileListParams: Sendable, Codable, Equatable {
    /// Opaque pagination cursor returned by a previous call.
    public var cursor: String?
    /// Optional working directory to resolve project config layers.
    public var cwd: String?
    /// Optional page size; defaults to the full result set.
    public var limit: UInt32?
    public init(cursor: String? = nil, cwd: String? = nil, limit: UInt32? = nil) {
        self.cursor = cursor; self.cwd = cwd; self.limit = limit
    }
}

/// `v2::PermissionProfileSummary` — `{ id, description? }`.
public struct PermissionProfileSummary: Sendable, Codable, Equatable {
    public var id: String
    public var description: String?
    public init(id: String, description: String? = nil) {
        self.id = id; self.description = description
    }
}

/// `v2::PermissionProfileListResponse` — `{ data, nextCursor? }`.
public struct PermissionProfileListResponse: Sendable, Codable, Equatable {
    public var data: [PermissionProfileSummary]
    public var nextCursor: String?
    public init(data: [PermissionProfileSummary], nextCursor: String? = nil) {
        self.data = data; self.nextCursor = nextCursor
    }
}

/// Built-in permission profile ids, in upstream order
/// (protocol/src/models.rs:302-308). Descriptions are `None` upstream.
public enum BuiltInPermissionProfile {
    public static let readOnly = ":read-only"
    public static let workspace = ":workspace"
    public static let dangerFullAccess = ":danger-full-access"
    public static let ordered = [readOnly, workspace, dangerFullAccess]
}

// MARK: skills/extraRoots/set

/// `v2::SkillsExtraRootsSetParams` — `{ extraRoots: [AbsolutePathBuf] }`.
/// Upstream requires each entry be an absolute, normalized path.
public struct SkillsExtraRootsSetParams: Sendable, Codable, Equatable {
    public var extraRoots: [String]
    public init(extraRoots: [String]) { self.extraRoots = extraRoots }
}

// MARK: account/usage/read

/// `v2::AccountTokenUsageSummary` — every field optional (`["integer","null"]`).
public struct AccountTokenUsageSummary: Sendable, Codable, Equatable {
    public var lifetimeTokens: Int64?
    public var peakDailyTokens: Int64?
    public var longestRunningTurnSec: Int64?
    public var currentStreakDays: Int64?
    public var longestStreakDays: Int64?
    public init(lifetimeTokens: Int64? = nil, peakDailyTokens: Int64? = nil,
                longestRunningTurnSec: Int64? = nil, currentStreakDays: Int64? = nil,
                longestStreakDays: Int64? = nil) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSec = longestRunningTurnSec
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

/// `v2::AccountTokenUsageDailyBucket` — `{ startDate, tokens }` (both required).
public struct AccountTokenUsageDailyBucket: Sendable, Codable, Equatable {
    public var startDate: String
    public var tokens: Int64
    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate; self.tokens = tokens
    }
}

/// `v2::GetAccountTokenUsageResponse` — `{ summary, dailyUsageBuckets? }`.
public struct GetAccountTokenUsageResponse: Sendable, Codable, Equatable {
    public var summary: AccountTokenUsageSummary
    public var dailyUsageBuckets: [AccountTokenUsageDailyBucket]?
    public init(summary: AccountTokenUsageSummary,
                dailyUsageBuckets: [AccountTokenUsageDailyBucket]? = nil) {
        self.summary = summary; self.dailyUsageBuckets = dailyUsageBuckets
    }
}

// MARK: notification bodies

/// `v2::ThreadDeletedNotification` — `{ threadId }`.
public struct ThreadDeletedBody: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public init(threadId: ThreadId) { self.threadId = threadId }
}

/// `v2::TurnModerationMetadataNotification` — `{ threadId, turnId, metadata }`
/// where `metadata` is an arbitrary JSON value (`"metadata": true` in the schema).
public struct TurnModerationMetadataBody: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var metadata: JSONValue
    public init(threadId: ThreadId, turnId: TurnId, metadata: JSONValue) {
        self.threadId = threadId; self.turnId = turnId; self.metadata = metadata
    }
}

/// `v2::ThreadSettingsUpdatedNotification` — `{ threadId, threadSettings }`.
/// Upstream's `ThreadSettings` is a large typed record (model, sandboxPolicy,
/// approvalPolicy, collaborationMode, …); the port round-trips it as raw JSON
/// (the same pragmatic shape used for `turn/start.collaborationMode`) so the
/// wire surface matches without rebuilding the full typed tree. Forward-declared
/// for parity — see the `threadSettingsUpdated` note in Events.swift.
public struct ThreadSettingsUpdatedBody: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var threadSettings: JSONValue
    public init(threadId: ThreadId, threadSettings: JSONValue) {
        self.threadId = threadId; self.threadSettings = threadSettings
    }
}
