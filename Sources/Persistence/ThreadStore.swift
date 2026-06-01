import Foundation
import InfraPrimitives
import ProtocolModel
import WireProtocol

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
    private var ephemeralPinned: Set<String> = []
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

    /// Compute the rollout file path for a NEW session, in upstream's
    /// date-partitioned layout: `sessions/YYYY/MM/DD/rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl`
    /// (rollout/src/list.rs:399). The created path is stored in the DB
    /// (`threads.rollout_path`) so resume/append always read it back via
    /// `resolvedRolloutPath` — sessions created under the legacy flat layout
    /// keep working because their stored path is honored unchanged.
    ///
    /// persistence-rollout finding 1: the date-partition directory
    /// (`sessions/YYYY/MM/DD`) and the filename timestamp
    /// (`rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl`) are computed in the
    /// operator's LOCAL wall-clock time, mirroring upstream
    /// `precompute_log_file_info` (rollout/src/recorder.rs:1329-1346) which uses
    /// `OffsetDateTime::now_local()`. This is `localtime_r`, not `gmtime_r`
    /// (UTC), so a Swift-created file lands in the same date folder as a
    /// CLI-written file for the same session. The `session_meta.timestamp`
    /// field stays on UTC (Rollout.swift `rustTimestamp`); only the path/name
    /// labeling tracks local time.
    private func rolloutPath(_ id: ThreadId) -> String {
        let secs = Int(Date().timeIntervalSince1970)
        var t = time_t(secs)
        var tmv = tm()
        localtime_r(&t, &tmv)
        let dateDir = String(format: "%04d/%02d/%02d",
                             tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday)
        let stamp = String(format: "%04d-%02d-%02dT%02d-%02d-%02d",
                           tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                           tmv.tm_hour, tmv.tm_min, tmv.tm_sec)
        return codexHome + "/sessions/\(dateDir)/rollout-\(stamp)-\(id.raw).jsonl"
    }

    /// The authoritative rollout path for an EXISTING durable thread: the value
    /// persisted in the DB at create time (honors both the new date-partitioned
    /// layout and any legacy flat path). Falls back to a freshly-computed path
    /// only when no row exists (should not happen for durable threads).
    private func resolvedRolloutPath(_ id: ThreadId) async -> String {
        if let row = try? await db.getThread(id.raw), !row.rolloutPath.isEmpty {
            return row.rolloutPath
        }
        return rolloutPath(id)
    }

    /// Stable synthetic path-label for an EPHEMERAL (in-memory, never-on-disk)
    /// thread. Deterministic per id so `conversationSummary` and its reverse
    /// path lookup agree — ephemeral threads have no real file, so the
    /// date-partitioned (timestamped, non-deterministic) layout must not be
    /// used for their label.
    private func ephemeralPathLabel(_ id: ThreadId) -> String {
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
        let w = try RolloutWriter(path: await resolvedRolloutPath(id), limits: limits)
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
        // persistence-rollout finding 3: upstream records `originator` as a
        // BARE originator id (`originator().value`, default `codex_cli_rs`,
        // overridable via CODEX_INTERNAL_ORIGINATOR_OVERRIDE) and `cli_version`
        // as the crate version separately (rollout/src/recorder.rs:678-679).
        // We previously hardcoded the combined string "codex-swift/0.1.0" for
        // `originator` and a literal "0.1.0" version. Source both from the
        // bound SessionConfig so the env override and any configured version
        // flow through faithfully.
        let cliVersion = config.cliVersion
        let originator = config.originator
        // persistence-rollout finding 1: record the session source faithfully.
        // Upstream's app-server defaults `session_source` to
        // `SessionSource::VSCode` (`app-server/src/lib.rs:386`), and
        // `SessionSource` is `#[default] VSCode` with `rename_all="lowercase"`
        // (`protocol.rs:2517-2522`), so the default on-disk value is "vscode".
        // `recorder.rs:683` records `config_snapshot.session_source` verbatim,
        // so a client-supplied `sessionStartSource` (e.g. "cli"/"resume") must
        // override the default. `INTERACTIVE_SESSION_SOURCES`
        // (`app-server/src/lib.rs:24-31`) excludes `Mcp`, so the prior
        // hardcoded "mcp" would make upstream's interactive-filtered listing
        // silently drop every Swift-written thread; "vscode" is interactive.
        let source = config.sessionStartSource ?? "vscode"
        return .sessionMeta(
            threadId: config.threadId,
            cwd: config.cwd,
            originator: originator,
            cliVersion: cliVersion,
            source: source,
            // persistence-rollout finding 3: record the LIVE provider id from
            // the bound SessionConfig (default "openai") instead of a hardcoded
            // literal — upstream `recorder.rs:685` records
            // `config.model_provider_id()`.
            modelProvider: config.modelProvider,
            baseInstructions: config.baseInstructions,
            memoryMode: nil,
            gitCommitHash: gitInfo?.sha,
            gitBranch: gitInfo?.branch,
            gitRepositoryURL: gitInfo?.originURL,
            // P1.1 / F5: carry fork provenance when this thread was forked.
            forkedFromId: config.forkedFromId)
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
        return try reader.readAll(path: await resolvedRolloutPath(id))
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
            case .compacted(_, let summary, _, _, _, _, let replacementHistory):
                // P1.1 / F2 fix — mirror upstream `rollout_reconstruction.rs`
                // replace-then-replay semantics. When the compaction record
                // carries a `replacement_history` (the post-compaction
                // model-visible baseline), RESET the accumulated items to that
                // vector and keep replaying subsequent records on top of it,
                // rather than collapsing the whole thread to a single summary
                // message. Only the legacy / summary-only form (no replacement
                // history) degrades to the single-agent-message collapse.
                if let replacementHistory, !replacementHistory.isEmpty {
                    items = replacementHistory
                } else {
                    items = [.agentMessage(id: ItemId.generate("compact"), text: summary)]
                }
            case .turnBoundary(_, let status, _, _, _):
                lastStatus = status
            case .turnContext, .tokenCount, .environmentRebound, .sessionMeta:
                continue
            }
        }
        return (items, lastStatus)
    }

    private func previewFrom(_ records: [RolloutRecord]) -> String {
        // P9.4 / cross-impl resume: each turn's user input now persists as a
        // `response_item` (role:user) line that the reader reconstructs as a
        // `.item(.userMessage)` record (the legacy `user_message` event_msg is
        // a deduped UI sidecar). The list/summary preview is the FIRST user
        // message, so match BOTH the response_item-derived `.item(.userMessage)`
        // and the legacy `.userInput` event-derived shape (older rollouts /
        // rollouts read without a turn cursor still surface as `.userInput`).
        for record in records {
            if case .item(_, .userMessage(_, let content)) = record {
                let text = content.compactMap(\.text).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
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
            records = try reader.readAll(path: row?.rolloutPath ?? rolloutPath(id))
            config = SessionConfig(
                threadId: id,
                cwd: row?.cwd ?? FileManager.default.currentDirectoryPath,
                model: row?.model ?? "gpt-5.5",
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
            case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _, _, _, _),
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
            case .compacted(_, let summary, _, _, _, _, let replacementHistory):
                // P1.1 / F2 fix: when the compaction carries the
                // post-compaction baseline (`replacement_history`), the turn's
                // model-visible items become that vector (replace-then-replay);
                // the summary-only legacy form degrades to a single message.
                if let replacementHistory, !replacementHistory.isEmpty {
                    byId[tid]?.items = replacementHistory
                } else {
                    byId[tid]?.items.append(
                        .agentMessage(id: ItemId.generate("compact"), text: summary))
                }
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
        let resolvedPath = await resolvedRolloutPath(id)
        let recs = try reader.readAll(path: resolvedPath)
        let kept = recordsDroppingLastTurns(recs, numTurns)
        // persistence-rollout finding 2: our port performs a DESTRUCTIVE
        // rewrite (drops the rolled-back turn groups from the file). We do NOT
        // also append a `thread_rolled_back` marker here: the turns are already
        // physically gone, so a trailing marker would cause our own reader (and
        // upstream reverse-replay) to drop an ADDITIONAL N turns on the next
        // read — a double-rollback. Cross-tool fidelity is instead provided on
        // the READ side: `RolloutReader` now interprets a `thread_rolled_back`
        // marker emitted by an upstream (non-destructive) client and applies
        // the same last-N-turn drop on replay (RolloutReader
        // .threadRolledBackNumTurns / .recordsDroppingLastTurns).
        try rewriteRollout(resolvedPath, kept)
        try await db.setCommittedSeq(id.raw, to: kept.count, updatedAt: now())
        return turnsFrom(kept)
    }

    private func recordsDroppingLastTurns(_ recs: [RolloutRecord], _ n: Int) -> [RolloutRecord] {
        var order: [String] = []
        for r in recs {
            let tid: String
            switch r {
            case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _, _, _, _),
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
            case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _, _, _, _),
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

    private func rewriteRollout(_ path: String, _ records: [RolloutRecord],
                                trailing: Data? = nil) throws {
        var data = Data()
        for r in records {
            data.append(try RolloutWriter.encodeLine(r))
            data.append(0x0A)
        }
        if let trailing {
            data.append(trailing)
            data.append(0x0A)
        }
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        let fh = try FileHandle(forUpdating: url)
        try fh.synchronize()
        try fh.close()
    }

    public func list(archived: Bool = false, limit: Int = 50) async throws -> [ThreadSummary] {
        let reader = RolloutReader()
        return try await db.listThreads(archived: archived, limit: limit).map { row in
            // persistence-rollout finding 3: recover the recorded provider from
            // the rollout head `session_meta` line (upstream `recorder.rs:685`)
            // instead of hardcoding "openai", so a provider-filtered listing
            // classifies each thread by its actual provider. The head read is a
            // single-line parse (`readSessionMeta`), not a full-file scan.
            var modelProvider = "openai"
            if !row.rolloutPath.isEmpty,
               case let .sessionMeta(_, _, _, _, _, mp, _, _, _, _, _, _, _, _, _, _, _)? =
                reader.readSessionMeta(path: row.rolloutPath),
               let mp {
                modelProvider = mp
            }
            return ThreadSummary(id: ThreadId(row.id), preview: "", modelProvider: modelProvider,
                          createdAt: row.createdAt, updatedAt: row.updatedAt,
                          ephemeral: row.ephemeral, name: row.name, cwd: row.cwd,
                          gitInfo: GitInfoState(
                            sha: row.gitSha, branch: row.gitBranch,
                            originURL: row.gitOriginURL).json,
                          pinned: row.pinned)
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
                path: ephemeralPathLabel(id),
                preview: previewFrom(records),
                timestamp: nil,
                updatedAt: nil,
                // persistence-rollout finding 3: source the provider from the
                // bound SessionConfig instead of hardcoding "openai".
                modelProvider: config.modelProvider,
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
        if let ephemeralId = ephemeralIds.first(where: { ephemeralPathLabel(ThreadId($0)) == path }) {
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
        // persistence-rollout finding 3: recover the recorded provider from the
        // persisted `session_meta` line (upstream `recorder.rs:685`) instead of
        // hardcoding "openai", so a provider-filtered listing classifies the
        // thread by its actual provider. Falls back to "openai" for legacy
        // rollouts whose session_meta predates the field.
        let modelProvider = Self.modelProvider(from: records)
        return ConversationSummaryState(
            conversationId: id,
            path: row.rolloutPath,
            preview: previewFrom(records),
            timestamp: Self.iso8601Seconds(row.createdAt),
            updatedAt: Self.iso8601Millis(row.updatedAt),
            modelProvider: modelProvider,
            cwd: row.cwd,
            cliVersion: "CodexKit/0.1",
            source: .string("appServer"),
            gitInfo: gitInfo)
    }

    private static func iso8601Seconds(_ seconds: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds)))
    }

    /// persistence-rollout finding: format a timestamp with MILLISECOND
    /// fractional-second precision to mirror upstream's `updated_at`, which is
    /// emitted via `to_rfc3339_opts(SecondsFormat::Millis, true)`
    /// (rollout/src/recorder.rs:1693) — distinct from `created_at`'s
    /// `SecondsFormat::Secs` (recorder.rs:1692). The `true` arg uses the `Z`
    /// UTC suffix, which `ISO8601DateFormatter` does by default. `.withInternetDateTime`
    /// (the formatter's default option set) plus `.withFractionalSeconds`
    /// yields `YYYY-MM-DDThh:mm:ss.SSSZ` — the millisecond RFC3339 shape.
    private static func iso8601Millis(_ seconds: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(seconds)))
    }

    /// persistence-rollout finding 3: extract the recorded `model_provider`
    /// from a thread's parsed `session_meta` record. Returns `"openai"` (the
    /// upstream/port default) when no session_meta carries a provider — i.e.
    /// legacy rollouts written before the provider was threaded through.
    static func modelProvider(from records: [RolloutRecord]) -> String {
        for r in records {
            if case let .sessionMeta(_, _, _, _, _, modelProvider, _, _, _, _, _, _, _, _, _, _, _) = r,
               let modelProvider {
                return modelProvider
            }
        }
        return "openai"
    }

    /// Threads currently loaded in memory (have an open writer or are
    /// ephemeral) — Codex `thread/loaded/list`.
    public func loadedList() -> [String] {
        Array(Set(writers.keys).union(ephemeralIds)).sorted()
    }

    /// Subdirectory names mirror upstream `rollout`'s constants
    /// (rollout/src/lib.rs:22-23): archived state is encoded by the rollout
    /// file's physical location, not only a DB column.
    static let sessionsSubdir = "sessions"
    static let archivedSessionsSubdir = "archived_sessions"

    /// Archive a thread by MOVING its rollout JSONL from `sessions/` into
    /// `archived_sessions/<basename>` and recording the new location +
    /// `archived_at` in the index. Mirrors upstream `archive_thread`
    /// (thread-store/src/local/archive_thread.rs:41-58): mkdir the archive
    /// folder, `rename` the canonical file, then `mark_archived`. The writer is
    /// quiesced first so the move is crash-consistent (no open fd into the old
    /// path), then the DB pointer advances — matching the rollout-before-index
    /// ordering used throughout this store.
    public func archive(_ id: ThreadId) async throws {
        try ensureSafe(id)
        if ephemeralIds.contains(id.raw) { return }
        guard let row = try await db.getThread(id.raw) else { return }
        // Already archived (idempotent): leave the file + flag untouched.
        if row.archived { return }
        if let w = writers[id.raw] { await w.close(); writers[id.raw] = nil }

        let sourcePath = row.rolloutPath
        let fileName = (sourcePath as NSString).lastPathComponent
        let archiveFolder = codexHome + "/" + Self.archivedSessionsSubdir
        let archivedPath = archiveFolder + "/" + fileName
        let fm = FileManager.default
        try fm.createDirectory(atPath: archiveFolder, withIntermediateDirectories: true)
        // Move the file only when it actually exists at the source. A durable
        // thread always has its rollout on disk; guard so a missing file does
        // not abort the archive flag flip.
        if fm.fileExists(atPath: sourcePath) {
            if fm.fileExists(atPath: archivedPath) { try? fm.removeItem(atPath: archivedPath) }
            try fm.moveItem(atPath: sourcePath, toPath: archivedPath)
        }
        try await db.markArchived(id.raw, rolloutPath: archivedPath, archivedAt: now())
    }

    /// Unarchive a thread: move its rollout file from `archived_sessions/` back
    /// into the date-partitioned `sessions/YYYY/MM/DD/` tree (recomputed from
    /// the filename timestamp), clear `archived_at`, and repoint the DB. Mirrors
    /// upstream `unarchive_thread` (thread-store/src/local/unarchive_thread.rs:55-80).
    public func unarchive(_ id: ThreadId) async throws {
        try ensureSafe(id)
        if ephemeralIds.contains(id.raw) { return }
        guard let row = try await db.getThread(id.raw) else { return }
        if !row.archived { return }
        if let w = writers[id.raw] { await w.close(); writers[id.raw] = nil }

        let archivedPath = row.rolloutPath
        let fileName = (archivedPath as NSString).lastPathComponent
        let fm = FileManager.default
        // Recompute the date-partitioned destination from the filename stamp,
        // mirroring upstream `rollout_date_parts` (rollout/src/list.rs:1419).
        let restoredPath: String
        if let (year, month, day) = Self.rolloutDateParts(fileName) {
            let destDir = codexHome + "/" + Self.sessionsSubdir + "/\(year)/\(month)/\(day)"
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            restoredPath = destDir + "/" + fileName
        } else {
            // No timestamp in the name (legacy flat layout): restore directly
            // under sessions/.
            let destDir = codexHome + "/" + Self.sessionsSubdir
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            restoredPath = destDir + "/" + fileName
        }
        if fm.fileExists(atPath: archivedPath) {
            if fm.fileExists(atPath: restoredPath) { try? fm.removeItem(atPath: restoredPath) }
            try fm.moveItem(atPath: archivedPath, toPath: restoredPath)
        }
        try await db.markUnarchived(id.raw, rolloutPath: restoredPath, updatedAt: now())
    }

    /// Extract `(year, month, day)` from a rollout filename of the form
    /// `rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl`. Faithful port of upstream
    /// `rollout_date_parts` (rollout/src/list.rs:1419-1426).
    static func rolloutDateParts(_ fileName: String) -> (String, String, String)? {
        guard fileName.hasPrefix("rollout-") else { return nil }
        let rest = String(fileName.dropFirst("rollout-".count))
        guard rest.count >= 10 else { return nil }
        let date = Array(rest.prefix(10))   // "YYYY-MM-DD"
        let year = String(date[0..<4])
        let month = String(date[5..<7])
        let day = String(date[8..<10])
        return (year, month, day)
    }
    public func setName(_ id: ThreadId, _ name: String) async throws {
        if ephemeralIds.contains(id.raw) { ephemeralName[id.raw] = name; return }
        try await db.setName(id.raw, name, updatedAt: now())
    }
    public func name(_ id: ThreadId) async throws -> String? {
        if ephemeralIds.contains(id.raw) { return ephemeralName[id.raw] }
        return try await db.getThread(id.raw)?.name
    }

    public func setPinned(_ id: ThreadId, _ pinned: Bool) async throws {
        if ephemeralIds.contains(id.raw) {
            if pinned { ephemeralPinned.insert(id.raw) } else { ephemeralPinned.remove(id.raw) }
            return
        }
        try await db.setPinned(id.raw, pinned, updatedAt: now())
    }
    public func pinned(_ id: ThreadId) async throws -> Bool {
        if ephemeralIds.contains(id.raw) { return ephemeralPinned.contains(id.raw) }
        return try await db.getThread(id.raw)?.pinned ?? false
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
