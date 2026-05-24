import Foundation
import InfraPrimitives
import ProtocolModel
import WireProtocol

public struct ReconstructedThread: Sendable, Equatable {
    public var config: SessionConfig
    public var items: [ThreadItem]
    public var lastTurnStatus: TurnStatus?
    public var turns: [ReconstructedTurn]
    public init(config: SessionConfig, items: [ThreadItem],
                lastTurnStatus: TurnStatus?, turns: [ReconstructedTurn] = []) {
        self.config = config; self.items = items
        self.lastTurnStatus = lastTurnStatus; self.turns = turns
    }
}

public struct ReconstructedTurn: Sendable, Equatable {
    public var id: TurnId
    public var items: [ThreadItem]
    public var status: TurnStatus
}

public struct ConversationSummaryState: Sendable, Equatable {
    public var conversationId: ThreadId
    public var path: String
    public var preview: String
    public var timestamp: String?
    public var updatedAt: String?
    public var modelProvider: String
    public var cwd: String
    public var cliVersion: String
    public var source: JSONValue
    public var gitInfo: JSONValue?
}

public struct GoalState: Sendable, Equatable {
    public var threadId: String
    public var objective: String
    public var status: ThreadGoalStatus
    public var tokenBudget: Int64?
    public var tokensUsed: Int64
    public var timeUsedSeconds: Int64
    public var createdAt: Int64
    public var updatedAt: Int64
    public func toProtocol() -> ThreadGoal {
        ThreadGoal(threadId: threadId, objective: objective, status: status,
                   tokenBudget: tokenBudget, tokensUsed: tokensUsed,
                   timeUsedSeconds: timeUsedSeconds, createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// Per-session durable store (rework §8.1). Rollout JSONL is the source of
/// truth; SQLite is the index. Recovery = deterministic replay. Crash-
/// consistent ordering: rollout is fsync'd **before** the index pointer
/// advances. Backs the full Codex thread surface (goals, memory mode, name,
/// archive/unarchive, rollback, turns/items listing, injection). Ephemeral
/// threads are in-memory only.
public actor ThreadStore {
    public let codexHome: String
    private let db: StateDB
    private let limits: Limits
    private var writers: [String: RolloutWriter] = [:]
    private var ephemeralIds: Set<String> = []
    private var ephemeralRecords: [String: [RolloutRecord]] = [:]
    private var ephemeralConfig: [String: SessionConfig] = [:]
    private var ephemeralGoals: [String: GoalState] = [:]
    private var ephemeralMemoryMode: [String: ThreadMemoryMode] = [:]
    private var ephemeralName: [String: String] = [:]
    private var ephemeralGitInfo: [String: GitInfoState] = [:]
    private let reader = RolloutReader()

    public struct GitInfoState: Sendable, Equatable {
        public var sha: String?
        public var branch: String?
        public var originURL: String?
        public init(sha: String? = nil, branch: String? = nil, originURL: String? = nil) {
            self.sha = sha; self.branch = branch; self.originURL = originURL
        }
        public var isEmpty: Bool { sha == nil && branch == nil && originURL == nil }
        public var json: JSONValue? {
            if isEmpty { return nil }
            return .object([
                "sha": sha.map(JSONValue.string) ?? .null,
                "branch": branch.map(JSONValue.string) ?? .null,
                "originUrl": originURL.map(JSONValue.string) ?? .null,
            ])
        }
    }

    public init(codexHome: String, limits: Limits) throws {
        self.codexHome = codexHome
        self.limits = limits
        try? FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        self.db = try StateDB(path: codexHome + "/state.sqlite3")
    }

    private func rolloutPath(_ id: ThreadId) -> String {
        codexHome + "/sessions/\(id.raw).rollout.jsonl"
    }
    private func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    private func ensureSafe(_ id: ThreadId) throws {
        guard id.isWellFormed else {
            throw RolloutError.io("unsafe thread id rejected")
        }
    }

    private func writer(for id: ThreadId) async throws -> RolloutWriter {
        try ensureSafe(id)
        if let w = writers[id.raw] { return w }
        let w = try RolloutWriter(path: rolloutPath(id), limits: limits)
        writers[id.raw] = w
        return w
    }

    public func create(_ config: SessionConfig) async throws -> ThreadSummary {
        try ensureSafe(config.threadId)
        let t = now()
        let metaRecord = Self.sessionMetaRecord(for: config, gitInfo: nil)
        if config.ephemeral {
            ephemeralIds.insert(config.threadId.raw)
            // P1.1 / F1: even ephemeral threads carry a session_meta preamble
            // so a snapshot / debug-dump of an in-memory thread looks the same
            // shape as a durable rollout file.
            ephemeralRecords[config.threadId.raw] = [metaRecord]
            ephemeralConfig[config.threadId.raw] = config
        } else {
            try await db.upsertThread(ThreadRow(
                id: config.threadId.raw, cwd: config.cwd, model: config.model,
                createdAt: t, updatedAt: t, archived: false, ephemeral: false,
                rolloutPath: rolloutPath(config.threadId), lastCommittedSeq: 0,
                name: nil, memoryMode: "enabled",
                gitSha: nil, gitBranch: nil, gitOriginURL: nil))
            let w = try await writer(for: config.threadId)
            // P1.1 / F1: append the session_meta record as the FIRST line so
            // upstream codex CLI / state-DB backfill / dynamic-tools backfill
            // can identify the thread by reading just the head of the file.
            // Only emit for a fresh file (existing rollouts already have one).
            let committed = await w.committedRecordCount()
            let pending = await w.pendingRecordCount()
            if committed == 0 && pending == 0 {
                try await w.append(metaRecord)
            }
        }
        return ThreadSummary(id: config.threadId, createdAt: t,
                             ephemeral: config.ephemeral, cwd: config.cwd)
    }

    /// Build the `session_meta` preamble record for a new thread (P1.1 / F1).
    /// Uses upstream codex's field names + defaults so the resulting JSONL is
    /// loadable by tooling that expects the upstream `SessionMetaLine` shape.
    static func sessionMetaRecord(for config: SessionConfig,
                                  gitInfo: GitInfoState?) -> RolloutRecord {
        // Upstream `originator` is "{originator_id}/{version}" (e.g.
        // "codex-cli/0.43.0"). Our Swift harness identifies itself as
        // CodexKit.
        let cliVersion = "0.1.0"
        let originator = "codex-swift/\(cliVersion)"
        // Upstream default `SessionSource` is `VSCode` (serialized as
        // "vscode"). The Swift app-server is also a GUI-style host so this
        // is the closest match; a future patch can plumb a per-host override.
        let source = "vscode"
        return .sessionMeta(
            threadId: config.threadId,
            cwd: config.cwd,
            originator: originator,
            cliVersion: cliVersion,
            source: source,
            modelProvider: "openai",
            baseInstructions: config.baseInstructions,
            memoryMode: nil,
            gitCommitHash: gitInfo?.sha,
            gitBranch: gitInfo?.branch,
            gitRepositoryURL: gitInfo?.originURL)
    }

    public func record(_ id: ThreadId, _ rec: RolloutRecord) async throws {
        if ephemeralIds.contains(id.raw) {
            ephemeralRecords[id.raw, default: []].append(rec)
            return
        }
        let w = try await writer(for: id)
        try await w.append(rec)
    }

    /// Durability barrier (turn boundary): fsync rollout, THEN advance the
    /// SQLite committed-seq pointer. No-op for ephemeral.
    public func durabilityBarrier(_ id: ThreadId) async throws {
        try ensureSafe(id)
        if ephemeralIds.contains(id.raw) { return }
        guard let w = writers[id.raw] else { return }
        let seq = try await w.durabilityBarrier()
        try await db.advanceCommittedSeq(id.raw, to: seq, updatedAt: now())
    }

    private func allRecords(_ id: ThreadId) async throws -> [RolloutRecord] {
        try ensureSafe(id)
        if ephemeralIds.contains(id.raw) { return ephemeralRecords[id.raw] ?? [] }
        try await durabilityBarrier(id)
        return try reader.readAll(path: rolloutPath(id))
    }

    private func itemsFrom(_ records: [RolloutRecord]) -> ([ThreadItem], TurnStatus?) {
        var items: [ThreadItem] = []
        var lastStatus: TurnStatus? = nil
        for r in records {
            switch r {
            case .userInput(_, let input):
                items.append(.userMessage(
                    id: ItemId.generate("u"),
                    content: input.map { i in
                        var c = UserMessageContent(text: i.text ?? "")
                        c.type = i.type; c.url = i.url; c.path = i.path
                        return c
                    }))
            case .item(_, let item):
                items.append(item)
            case .compacted(_, let summary, _, _, _, _, _):
                items = [.agentMessage(id: ItemId.generate("compact"), text: summary)]
            case .turnBoundary(_, let status, _, _, _):
                lastStatus = status
            case .turnContext, .tokenCount, .environmentRebound, .sessionMeta:
                continue
            }
        }
        return (items, lastStatus)
    }

    private func previewFrom(_ records: [RolloutRecord]) -> String {
        for record in records {
            if case .userInput(_, let input) = record {
                let text = input.compactMap(\.text).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        for record in records {
            if case .item(_, .agentMessage(_, let text)) = record {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    public func reconstruct(_ id: ThreadId) async throws -> ReconstructedThread {
        try ensureSafe(id)
        let records: [RolloutRecord]
        var config: SessionConfig
        if ephemeralIds.contains(id.raw) {
            records = ephemeralRecords[id.raw] ?? []
            config = ephemeralConfig[id.raw]
                ?? SessionConfig(threadId: id, cwd: FileManager.default.currentDirectoryPath)
        } else {
            let row = try await db.getThread(id.raw)
            records = try reader.readAll(path: rolloutPath(id))
            config = SessionConfig(
                threadId: id,
                cwd: row?.cwd ?? FileManager.default.currentDirectoryPath,
                model: row?.model ?? "gpt-5.1-codex",
                ephemeral: row?.ephemeral ?? false)
        }
        // Apply the latest environment-rebind record. The thread's remote
        // environment is durable through these records: thread/start emits
        // one for the initial selection, and each turn/start switch emits
        // another. Replay reproduces the binding that was active at the most
        // recent turn boundary.
        for record in records {
            if case .environmentRebound(_, let envId, let url) = record {
                if let url, !url.isEmpty {
                    config.remoteEnvironment = .init(environmentId: envId,
                                                     execServerUrl: url)
                } else {
                    config.remoteEnvironment = nil
                }
            }
        }
        let (items, lastStatus) = itemsFrom(records)
        return ReconstructedThread(config: config, items: items,
                                   lastTurnStatus: lastStatus,
                                   turns: turnsFrom(records))
    }

    /// Group rollout records by `turnId` (preserving order) into turns with a
    /// resolved status (Codex `thread/turns/list`).
    private func turnsFrom(_ records: [RolloutRecord]) -> [ReconstructedTurn] {
        var order: [String] = []
        var byId: [String: (items: [ThreadItem], status: TurnStatus)] = [:]
        for r in records {
            // Session_meta is the file-level preamble (no turnId) so it never
            // contributes to a turn group.
            if case .sessionMeta = r { continue }
            let tid: String
            switch r {
            case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _),
                 .compacted(let t, _, _, _, _, _, _), .tokenCount(let t, _, _, _, _, _, _, _, _, _, _, _), .turnBoundary(let t, _, _, _, _),
                 .environmentRebound(let t, _, _):
                tid = t.raw
            case .sessionMeta:
                continue
            }
            if byId[tid] == nil { byId[tid] = ([], .inProgress); order.append(tid) }
            switch r {
            case .userInput(_, let input):
                byId[tid]?.items.append(.userMessage(
                    id: ItemId.generate("u"),
                    content: input.map { i in
                        var c = UserMessageContent(text: i.text ?? "")
                        c.type = i.type; c.url = i.url; c.path = i.path
                        return c
                    }))
            case .item(_, let item):
                byId[tid]?.items.append(item)
            case .compacted(_, let summary, _, _, _, _, _):
                byId[tid]?.items.append(.agentMessage(id: ItemId.generate("compact"), text: summary))
            case .turnBoundary(_, let status, _, _, _):
                byId[tid]?.status = status
            case .turnContext, .tokenCount, .environmentRebound, .sessionMeta:
                continue
            }
        }
        return order.compactMap { id in
            byId[id].map { ReconstructedTurn(id: TurnId(id), items: $0.items, status: $0.status) }
        }
    }

    public func turnsList(_ id: ThreadId) async throws -> [ReconstructedTurn] {
        turnsFrom(try await allRecords(id))
    }

    public func turnItems(_ id: ThreadId, turn: TurnId) async throws -> [ThreadItem] {
        turnsFrom(try await allRecords(id)).first(where: { $0.id == turn })?.items ?? []
    }

    /// Append raw Responses-API-shaped items as agent messages (best-effort
    /// mapping, Codex `thread/inject_items`).
    public func injectItems(_ id: ThreadId, _ items: [JSONValue]) async throws {
        let turn = TurnId.generate()
        for v in items {
            let text = Self.injectedItemText(v, limits: limits)
            try await record(id, .item(turnId: turn,
                item: .agentMessage(id: ItemId.generate("inj"), text: text)))
        }
        try await record(id, .turnBoundary(turnId: turn, status: .completed))
        try await durabilityBarrier(id)
    }

    public func injectedItemTexts(_ items: [JSONValue]) -> [String] {
        items.map { Self.injectedItemText($0, limits: limits) }
    }

    public static func injectedItemText(_ value: JSONValue, limits: Limits) -> String {
        if let s = value["content"]?.stringValue ?? value["text"]?.stringValue {
            return s
        }
        // Foundation's encoder is recursive enough to crash on hostile
        // programmatic JSONValue trees even though wire decoding has its own
        // depth guard. Fail closed at this persistence boundary.
        let maxSafeEncodeDepth = Swift.min(limits.clamped().maxJSONNestingDepth, 128)
        if jsonDepthExceeds(value, maxDepth: maxSafeEncodeDepth) {
            return "[injected JSON item omitted: nesting depth exceeds \(maxSafeEncodeDepth)]"
        }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        if data.count > limits.clamped().maxInboundMessageBytes {
            return "[injected JSON item omitted: encoded size exceeds limit]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonDepthExceeds(_ value: JSONValue, maxDepth: Int) -> Bool {
        var stack: [(JSONValue, Int)] = [(value, 1)]
        while let (next, depth) = stack.popLast() {
            if depth > maxDepth { return true }
            switch next {
            case .array(let values):
                if depth == maxDepth, !values.isEmpty { return true }
                stack.append(contentsOf: values.map { ($0, depth + 1) })
            case .object(let fields):
                if depth == maxDepth, !fields.isEmpty { return true }
                stack.append(contentsOf: fields.values.map { ($0, depth + 1) })
            case .null, .bool, .int, .double, .string:
                continue
            }
        }
        return false
    }

    /// Drop the last `numTurns` turn groups from the durable rollout (Codex
    /// `thread/rollback`). Only modifies history; file changes are the
    /// client's responsibility.
    @discardableResult
    public func rollback(_ id: ThreadId, numTurns: Int) async throws -> [ReconstructedTurn] {
        try ensureSafe(id)
        guard numTurns >= 1 else { return try await turnsList(id) }
        if ephemeralIds.contains(id.raw) {
            let recs = ephemeralRecords[id.raw] ?? []
            let kept = recordsDroppingLastTurns(recs, numTurns)
            ephemeralRecords[id.raw] = kept
            return turnsFrom(kept)
        }
        try await durabilityBarrier(id)
        if let w = writers[id.raw] { await w.close(); writers[id.raw] = nil }
        let recs = try reader.readAll(path: rolloutPath(id))
        let kept = recordsDroppingLastTurns(recs, numTurns)
        try rewriteRollout(id, kept)
        try await db.setCommittedSeq(id.raw, to: kept.count, updatedAt: now())
        return turnsFrom(kept)
    }

    private func recordsDroppingLastTurns(_ recs: [RolloutRecord], _ n: Int) -> [RolloutRecord] {
        var order: [String] = []
        for r in recs {
            let tid: String
            switch r {
            case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _),
                 .compacted(let t, _, _, _, _, _, _), .tokenCount(let t, _, _, _, _, _, _, _, _, _, _, _), .turnBoundary(let t, _, _, _, _),
                 .environmentRebound(let t, _, _):
                tid = t.raw
            case .sessionMeta:
                // The file-level preamble has no turnId and is preserved
                // across rollback (it identifies the thread itself).
                continue
            }
            if !order.contains(tid) { order.append(tid) }
        }
        guard !order.isEmpty else { return recs }
        let drop = Set(order.suffix(n))
        return recs.filter { r in
            let tid: String
            switch r {
            case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _),
                 .compacted(let t, _, _, _, _, _, _), .tokenCount(let t, _, _, _, _, _, _, _, _, _, _, _), .turnBoundary(let t, _, _, _, _),
                 .environmentRebound(let t, _, _):
                tid = t.raw
            case .sessionMeta:
                // Always keep the session_meta preamble across rollbacks.
                return true
            }
            return !drop.contains(tid)
        }
    }

    private func rewriteRollout(_ id: ThreadId, _ records: [RolloutRecord]) throws {
        let path = rolloutPath(id)
        var data = Data()
        for r in records {
            data.append(try RolloutWriter.encodeLine(r))
            data.append(0x0A)
        }
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        let fh = try FileHandle(forUpdating: url)
        try fh.synchronize()
        try fh.close()
    }

    public func list(archived: Bool = false, limit: Int = 50) async throws -> [ThreadSummary] {
        try await db.listThreads(archived: archived, limit: limit).map {
            ThreadSummary(id: ThreadId($0.id), preview: "", modelProvider: "openai",
                          createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                          ephemeral: $0.ephemeral, name: $0.name, cwd: $0.cwd,
                          gitInfo: GitInfoState(
                            sha: $0.gitSha, branch: $0.gitBranch,
                            originURL: $0.gitOriginURL).json)
        }
    }

    public func conversationSummary(id: ThreadId) async throws -> ConversationSummaryState? {
        try ensureSafe(id)
        if ephemeralIds.contains(id.raw) {
            let records = ephemeralRecords[id.raw] ?? []
            let config = ephemeralConfig[id.raw]
                ?? SessionConfig(threadId: id, cwd: FileManager.default.currentDirectoryPath)
            return ConversationSummaryState(
                conversationId: id,
                path: rolloutPath(id),
                preview: previewFrom(records),
                timestamp: nil,
                updatedAt: nil,
                modelProvider: "openai",
                cwd: config.cwd,
                cliVersion: "CodexKit/0.1",
                source: .string("appServer"),
                gitInfo: ephemeralGitInfo[id.raw]?.json)
        }
        guard let row = try await db.getThread(id.raw) else { return nil }
        return try await conversationSummary(row: row)
    }

    public func conversationSummary(rolloutPath path: String) async throws -> ConversationSummaryState? {
        guard path.hasPrefix("/") else { throw RolloutError.io("rolloutPath must be absolute") }
        if let ephemeralId = ephemeralIds.first(where: { rolloutPath(ThreadId($0)) == path }) {
            return try await conversationSummary(id: ThreadId(ephemeralId))
        }
        guard let row = try await db.getThreadByRolloutPath(path) else { return nil }
        return try await conversationSummary(row: row)
    }

    private func conversationSummary(row: ThreadRow) async throws -> ConversationSummaryState {
        let id = ThreadId(row.id)
        let records = try await allRecords(id)
        let gitInfo = GitInfoState(sha: row.gitSha, branch: row.gitBranch,
                                   originURL: row.gitOriginURL).json
        return ConversationSummaryState(
            conversationId: id,
            path: row.rolloutPath,
            preview: previewFrom(records),
            timestamp: Self.iso8601Seconds(row.createdAt),
            updatedAt: Self.iso8601Seconds(row.updatedAt),
            modelProvider: "openai",
            cwd: row.cwd,
            cliVersion: "CodexKit/0.1",
            source: .string("appServer"),
            gitInfo: gitInfo)
    }

    private static func iso8601Seconds(_ seconds: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds)))
    }

    /// Threads currently loaded in memory (have an open writer or are
    /// ephemeral) — Codex `thread/loaded/list`.
    public func loadedList() -> [String] {
        Array(Set(writers.keys).union(ephemeralIds)).sorted()
    }

    public func archive(_ id: ThreadId) async throws {
        if ephemeralIds.contains(id.raw) { return }
        try await db.setArchived(id.raw, true, updatedAt: now())
    }
    public func unarchive(_ id: ThreadId) async throws {
        if ephemeralIds.contains(id.raw) { return }
        try await db.setArchived(id.raw, false, updatedAt: now())
    }
    public func setName(_ id: ThreadId, _ name: String) async throws {
        if ephemeralIds.contains(id.raw) { ephemeralName[id.raw] = name; return }
        try await db.setName(id.raw, name, updatedAt: now())
    }
    public func name(_ id: ThreadId) async throws -> String? {
        if ephemeralIds.contains(id.raw) { return ephemeralName[id.raw] }
        return try await db.getThread(id.raw)?.name
    }

    public func gitInfo(_ id: ThreadId) async throws -> GitInfoState? {
        if ephemeralIds.contains(id.raw) { return ephemeralGitInfo[id.raw] }
        guard let row = try await db.getThread(id.raw) else { return nil }
        let info = GitInfoState(sha: row.gitSha, branch: row.gitBranch,
                                originURL: row.gitOriginURL)
        return info.isEmpty ? nil : info
    }

    public func setGitInfo(_ id: ThreadId, _ info: GitInfoState?) async throws {
        if ephemeralIds.contains(id.raw) {
            ephemeralGitInfo[id.raw] = info?.isEmpty == true ? nil : info
            return
        }
        try await db.setGitInfo(id.raw, sha: info?.sha, branch: info?.branch,
                                originURL: info?.originURL, updatedAt: now())
    }

    public func setMemoryMode(_ id: ThreadId, _ mode: ThreadMemoryMode) async throws {
        if ephemeralIds.contains(id.raw) { ephemeralMemoryMode[id.raw] = mode; return }
        try await db.setMemoryMode(id.raw, mode.rawValue, updatedAt: now())
    }
    public func memoryMode(_ id: ThreadId) async throws -> ThreadMemoryMode {
        if ephemeralIds.contains(id.raw) { return ephemeralMemoryMode[id.raw] ?? .enabled }
        let raw = try await db.getThread(id.raw)?.memoryMode ?? "enabled"
        return ThreadMemoryMode(rawValue: raw) ?? .enabled
    }

    // MARK: Goals (Codex thread/goal/*)

    public func goalGet(_ id: ThreadId) async throws -> GoalState? {
        if ephemeralIds.contains(id.raw) { return ephemeralGoals[id.raw] }
        guard let g = try await db.getGoal(id.raw) else { return nil }
        return GoalState(threadId: g.threadId, objective: g.objective,
                         status: ThreadGoalStatus(rawValue: g.status) ?? .active,
                         tokenBudget: g.tokenBudget, tokensUsed: g.tokensUsed,
                         timeUsedSeconds: g.timeUsedSeconds,
                         createdAt: g.createdAt, updatedAt: g.updatedAt)
    }

    public func goalSet(_ id: ThreadId, objective: String?, status: ThreadGoalStatus?,
                        tokenBudget: Int64??) async throws -> GoalState {
        let t = now()
        let existing = try await goalGet(id)
        var g = existing ?? GoalState(threadId: id.raw, objective: objective ?? "",
            status: .active, tokenBudget: nil, tokensUsed: 0, timeUsedSeconds: 0,
            createdAt: t, updatedAt: t)
        if let objective { g.objective = objective }
        if let status { g.status = status }
        if let tb = tokenBudget { g.tokenBudget = tb }   // double-optional: present clears/sets
        g.updatedAt = t
        if ephemeralIds.contains(id.raw) { ephemeralGoals[id.raw] = g }
        else {
            try await db.upsertGoal(StateDB.GoalRowAlias(
                threadId: g.threadId, objective: g.objective, status: g.status.rawValue,
                tokenBudget: g.tokenBudget, tokensUsed: g.tokensUsed,
                timeUsedSeconds: g.timeUsedSeconds, createdAt: g.createdAt, updatedAt: g.updatedAt))
        }
        return g
    }

    public func goalAddUsage(_ id: ThreadId, tokens: Int64, seconds: Int64) async throws {
        let t = max(0, tokens)
        let s = max(0, seconds)
        if ephemeralIds.contains(id.raw) {
            guard var g = ephemeralGoals[id.raw] else { return }
            g.tokensUsed += t
            g.timeUsedSeconds += s
            if let b = g.tokenBudget, g.tokensUsed >= b, g.status == .active {
                g.status = .budgetLimited
            }
            g.updatedAt = now()
            ephemeralGoals[id.raw] = g
            return
        }
        try await db.addGoalUsage(id.raw, tokens: t, seconds: s, updatedAt: now())
    }

    @discardableResult
    public func goalClear(_ id: ThreadId) async throws -> Bool {
        if ephemeralIds.contains(id.raw) {
            let had = ephemeralGoals[id.raw] != nil
            ephemeralGoals[id.raw] = nil
            return had
        }
        return try await db.clearGoal(id.raw)
    }

    public func quiesce(_ id: ThreadId) async throws {
        try ensureSafe(id)
        if ephemeralIds.contains(id.raw) {
            ephemeralRecords[id.raw] = nil
            ephemeralConfig[id.raw] = nil
            ephemeralGoals[id.raw] = nil
            ephemeralMemoryMode[id.raw] = nil
            ephemeralName[id.raw] = nil
            ephemeralGitInfo[id.raw] = nil
            ephemeralIds.remove(id.raw)
            return
        }
        try await durabilityBarrier(id)
        if let w = writers[id.raw] { await w.close(); writers[id.raw] = nil }
        try? await db.checkpoint()
    }

    public func isEphemeral(_ id: ThreadId) -> Bool { ephemeralIds.contains(id.raw) }
}

extension StateDB {
    /// Convenience alias so ThreadStore can construct goal rows without
    /// importing the row type by its bare name in multiple call sites.
    public typealias GoalRowAlias = GoalRow
}
