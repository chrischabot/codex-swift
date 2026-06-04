import Foundation

/// The durable ledger + lifecycle driver. `submit` dedups by idempotency key,
/// asks the provider, and either completes immediately (inline) or queues. The
/// supervisor-resident poller calls `advance` until every queued task is
/// terminal; on completion the injected `deliver` mints the signed URL + pushes.
public actor MediaTaskLedger {
    /// Deliver a finished task (mint a MediaToken URL + push #7). Returns success.
    public typealias Deliver = @Sendable (MediaTask) async -> Bool

    private var tasks: [String: MediaTask]
    private let providers: [String: any MediaProvider]
    private let deliver: Deliver
    private let store: (any MediaStore)?
    private let now: @Sendable () -> Int64
    private let mintId: @Sendable () -> String

    public init(providers: [any MediaProvider],
                deliver: @escaping Deliver,
                store: (any MediaStore)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                mintId: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.tasks = [:]
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.deliver = deliver
        self.store = store
        self.now = now
        self.mintId = mintId
    }

    public func loadFromStore() async {
        if let store { for t in await store.load() { tasks[t.id] = t } }
    }

    public func task(_ id: String) -> MediaTask? { tasks[id] }
    public func all() -> [MediaTask] { tasks.values.sorted { $0.createdAt < $1.createdAt } }

    /// Submit a generation request. Returns the task (already `.done` on the fast
    /// path, else `.queued`). A repeat of an in-flight/finished idempotency key
    /// returns the EXISTING task instead of resubmitting.
    public func submit(kind: MediaKind, prompt: String,
                       providerId: String? = nil,
                       idempotencyKey: String? = nil,
                       deliverTo: String? = nil) async -> MediaTask {
        if let key = idempotencyKey, let existing = tasks.values.first(where: { $0.idempotencyKey == key }) {
            return existing
        }
        // Pick the provider: the named one, else the first that supports the kind.
        let provider: (any MediaProvider)?
        if let providerId { provider = providers[providerId] }
        else { provider = providers.values.first { $0.supports(kind) } }
        guard let provider, provider.supports(kind) else {
            let t = MediaTask(id: mintId(), kind: kind, provider: providerId ?? "?", prompt: prompt,
                              status: .failed, idempotencyKey: idempotencyKey, deliverTo: deliverTo,
                              error: "no provider for \(kind.rawValue)", createdAt: now())
            tasks[t.id] = t; await persist()
            return t
        }
        var task = MediaTask(id: mintId(), kind: kind, provider: provider.id, prompt: prompt,
                             status: .queued, idempotencyKey: idempotencyKey, deliverTo: deliverTo,
                             createdAt: now())
        switch await provider.submit(kind: kind, prompt: prompt) {
        case .inline(let path):
            task.status = .done
            task.assetPath = path
            tasks[task.id] = task
            await finishDelivery(task.id)
        case .queued(let pid):
            task.status = .running
            task.providerTaskId = pid
            tasks[task.id] = task
        case .failed(let why):
            task.status = .failed
            task.error = why
            tasks[task.id] = task
        }
        let result = tasks[task.id] ?? task   // capture before retention may prune
        enforceRetention()
        await persist()
        return result
    }

    /// Poll every non-terminal task once; complete + deliver the finished ones.
    /// Returns the ids that reached a terminal state this pass.
    @discardableResult
    public func advance() async -> [String] {
        var settled: [String] = []
        var changed = false
        for var task in tasks.values where !task.isTerminal {
            guard let provider = providers[task.provider], let pid = task.providerTaskId else { continue }
            switch await provider.poll(providerTaskId: pid) {
            case .pending:
                continue
            case .done(let path):
                task.status = .done
                task.assetPath = path
                tasks[task.id] = task
                await finishDelivery(task.id)
                settled.append(task.id); changed = true
            case .failed(let why):
                task.status = .failed
                task.error = why
                tasks[task.id] = task
                settled.append(task.id); changed = true
            }
        }
        // Re-attempt delivery for DONE-but-UNDELIVERED tasks: delivery is
        // decoupled from terminal status, so a transient push failure (5xx /
        // SSRF-blocked) is retried on a later pass instead of silently dropping
        // the generated asset. Bounded by deliveryAttempts.
        for task in tasks.values
            where task.status == .done && task.deliverTo != nil
                && task.deliveredAt == nil && task.deliveryAttempts < Self.maxDeliveryAttempts {
            await finishDelivery(task.id)
            changed = true
        }
        if enforceRetention() { changed = true }
        if changed { await persist() }
        return settled
    }

    static let maxDeliveryAttempts = 10
    /// Cap on retained TERMINAL tasks. A long-running daemon generates terminal
    /// tasks indefinitely; without a cap the dict + the durable file grow without
    /// bound. Non-terminal tasks are never dropped.
    static let maxRetainedTerminal = 500

    /// Drop the oldest terminal tasks beyond `maxRetainedTerminal`. A dropped
    /// task loses its idempotency-dedup history (acceptable for old tasks).
    /// Returns true if anything was dropped (→ caller persists).
    @discardableResult
    private func enforceRetention() -> Bool {
        let terminal = tasks.values.filter { $0.isTerminal }
        guard terminal.count > Self.maxRetainedTerminal else { return false }
        let drop = terminal.sorted { $0.createdAt < $1.createdAt }
            .prefix(terminal.count - Self.maxRetainedTerminal)
        for t in drop { tasks.removeValue(forKey: t.id) }
        return true
    }

    private func finishDelivery(_ id: String) async {
        guard var task = tasks[id], task.status == .done, task.deliverTo != nil,
              task.deliveredAt == nil, task.deliveryAttempts < Self.maxDeliveryAttempts else { return }
        task.deliveryAttempts += 1
        tasks[id] = task
        if await deliver(task) {
            task.deliveredAt = now()
            tasks[id] = task
        }
    }

    private func persist() async { if let store { await store.save(Array(tasks.values)) } }
}

public protocol MediaStore: Sendable {
    func load() async -> [MediaTask]
    func save(_ tasks: [MediaTask]) async
}

public actor MemoryMediaStore: MediaStore {
    private var tasks: [MediaTask]
    public init(_ initial: [MediaTask] = []) { self.tasks = initial }
    public func load() -> [MediaTask] { tasks }
    public func save(_ t: [MediaTask]) { tasks = t }
}
