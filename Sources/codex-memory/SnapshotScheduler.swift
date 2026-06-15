import Foundation
import MemoryStore

/// Once-per-day maintenance: VACUUM INTO a date-stamped backup of the SQLite
/// store, git-commit the JSONL archive, then prune everything older than the
/// configured retention window. Designed to live in-process inside the
/// running daemon — the cadence isn't tight enough to warrant a cron.
public actor SnapshotScheduler {
    public struct Config: Sendable {
        public var intervalSeconds: Double
        public var retentionDays: Int
        public var clock: @Sendable () -> Date
        /// Run the nightly knowledge-maintenance cycle (gbrain.md Wave 1.7) before
        /// DB hygiene. Property-level default keeps the init signature stable.
        public var runMaintenanceCycle: Bool = true
        public init(intervalSeconds: Double = 24 * 60 * 60,
                    retentionDays: Int = 30,
                    clock: @escaping @Sendable () -> Date = { Date() }) {
            self.intervalSeconds = intervalSeconds
            self.retentionDays = retentionDays
            self.clock = clock
        }
    }

    private let store: MemoryStore
    private let archive: MemoryArchive
    private let config: Config
    private var task: Task<Void, Never>?

    public init(store: MemoryStore, archive: MemoryArchive, config: Config = Config()) {
        self.store = store
        self.archive = archive
        self.config = config
    }

    public func start() {
        guard task == nil else { return }
        let store = self.store
        let archive = self.archive
        let cfg = self.config
        task = Task {
            while !Task.isCancelled {
                do {
                    try await SnapshotScheduler.runOnce(
                        store: store, archive: archive, config: cfg)
                } catch {
                    FileHandle.standardError.write(
                        Data("snapshot run failed: \(error)\n".utf8))
                }
                try? await Task.sleep(for: .seconds(cfg.intervalSeconds))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One-shot snapshot pass. Public so `codex-memory snapshot` can drive
    /// it from the CLI without bringing up the whole daemon loop.
    public static func runOnce(store: MemoryStore,
                               archive: MemoryArchive,
                               config: Config) async throws {
        let date = config.clock()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: date)
        // Knowledge maintenance settles BEFORE DB hygiene (gbrain.md Wave 1.7):
        // freshness/drift/librarian transitions, then VACUUM the result.
        if config.runMaintenanceCycle {
            let report = await MaintenanceCycle(store: store)
                .run(now: Int64(date.timeIntervalSince1970))
            let summary = report.phases.map { "\($0.name)=\($0.touched)" }.joined(separator: " ")
            FileHandle.standardOutput.write(Data("maintenance cycle: \(summary)\n".utf8))
        }
        let snapshotPath = archive.root + "/snapshots/memory.db.\(stamp).bak"
        try await store.vacuumInto(snapshotPath)
        await archive.snapshotIntoGit(
            commitMessage: "codex-memory snapshot \(stamp)")
        await archive.prune(retentionDays: config.retentionDays, now: date)
    }
}
