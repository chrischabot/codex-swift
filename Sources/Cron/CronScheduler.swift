import Foundation

/// A scheduled job. `skipMemory` defaults TRUE: an unattended run must not
/// silently rewrite the user model, so memory writes are off unless the operator
/// opts in. `prompt` is the turn the job runs; `deliverTo` is an optional push
/// target (#7) for the result.
public struct CronJob: Sendable, Equatable, Codable {
    public var id: String
    public var schedule: Schedule
    public var prompt: String
    public var enabled: Bool
    public var skipMemory: Bool
    public var deliverTo: String?
    public var lastRunAt: Int64?
    public var createdAt: Int64

    public init(id: String, schedule: Schedule, prompt: String,
                enabled: Bool = true, skipMemory: Bool = true,
                deliverTo: String? = nil, lastRunAt: Int64? = nil, createdAt: Int64) {
        self.id = id; self.schedule = schedule; self.prompt = prompt
        self.enabled = enabled; self.skipMemory = skipMemory; self.deliverTo = deliverTo
        self.lastRunAt = lastRunAt; self.createdAt = createdAt
    }
}

/// Durable job storage (JSON under $CODEX_HOME).
public protocol CronStore: Sendable {
    func load() async -> [CronJob]
    func save(_ jobs: [CronJob]) async
}

public actor FileCronStore: CronStore {
    private let path: String
    public init(path: String) { self.path = path }
    public func load() -> [CronJob] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([CronJob].self, from: d)) ?? []
    }
    public func save(_ jobs: [CronJob]) {
        guard let d = try? JSONEncoder().encode(jobs) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

public actor MemoryCronStore: CronStore {
    private var jobs: [CronJob]
    public init(_ initial: [CronJob] = []) { self.jobs = initial }
    public func load() -> [CronJob] { jobs }
    public func save(_ j: [CronJob]) { jobs = j }
}

public actor CronScheduler {
    /// Fire a job's turn; returns whether it ran successfully. codexd wires this
    /// to a supervisor turn (honoring `skipMemory`) + a push delivery (#7).
    public typealias Runner = @Sendable (CronJob) async -> Bool

    private var jobs: [String: CronJob]
    private let store: any CronStore
    private let graceSeconds: Int64
    private let run: Runner

    /// - graceSeconds: catch-up window. A missed fire WITHIN this window of `now`
    ///   is caught up (run once); an older missed fire is FAST-FORWARDED (skipped,
    ///   not run) so a daemon that was down for a week doesn't replay a week of
    ///   stale ticks. (hermes grace-window semantics.)
    public init(store: any CronStore, graceSeconds: Int64 = 3600, run: @escaping Runner) {
        self.jobs = [:]
        self.store = store
        self.graceSeconds = Swift.max(0, graceSeconds)
        self.run = run
    }

    public func loadFromStore() async {
        for job in await store.load() { jobs[job.id] = job }
    }

    public func upsert(_ job: CronJob) async {
        jobs[job.id] = job
        await persist()
    }

    public func remove(_ id: String) async {
        jobs[id] = nil
        await persist()
    }

    public func list() -> [CronJob] { jobs.values.sorted { $0.id < $1.id } }

    /// The jobs that should FIRE at `now` (enabled, due, within the grace window).
    public func due(now: Int64) -> [CronJob] {
        jobs.values.filter { job in
            guard job.enabled else { return false }
            let anchor = job.lastRunAt ?? job.createdAt
            guard let next = job.schedule.next(after: anchor), next <= now else { return false }
            return (now - next) <= graceSeconds
        }.sorted { $0.id < $1.id }
    }

    /// Advance the schedule at `now`: fire due jobs, fast-forward stale ones,
    /// and one-shot-disable fired `.at` jobs. Returns the ids that ran.
    @discardableResult
    public func tick(now: Int64) async -> [String] {
        var ran: [String] = []
        for var job in jobs.values where job.enabled {
            let anchor = job.lastRunAt ?? job.createdAt
            guard let next = job.schedule.next(after: anchor), next <= now else { continue }
            if (now - next) <= graceSeconds {
                // Due (or caught up within grace): run it.
                _ = await run(job)
                ran.append(job.id)
                job.lastRunAt = now
                if case .at = job.schedule { job.enabled = false }   // one-shot
            } else {
                // Stale missed fire: fast-forward without running.
                job.lastRunAt = now
                if case .at = job.schedule { job.enabled = false }
            }
            jobs[job.id] = job
        }
        if !ran.isEmpty || true { await persist() }
        return ran
    }

    private func persist() async { await store.save(Array(jobs.values)) }
}
