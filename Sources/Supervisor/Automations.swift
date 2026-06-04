import Foundation
import ProtocolModel
import Persistence

/// A scheduled (or manual) automation: a saved prompt the agent runs on a
/// schedule. Persisted to `$CODEX_HOME/automations.json` so it survives restart
/// (the web UI previously kept these in volatile in-memory state).
public struct Automation: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    /// "manual" | "hourly" | "daily" | "weekly" | "<seconds>"
    public var schedule: String
    public var prompt: String
    public var enabled: Bool
    public var cwd: String?
    public var model: String?
    public var lastRunAt: Int64?
    public var lastThreadId: String?

    public init(id: String, name: String, schedule: String, prompt: String,
                enabled: Bool = true, cwd: String? = nil, model: String? = nil,
                lastRunAt: Int64? = nil, lastThreadId: String? = nil) {
        self.id = id; self.name = name; self.schedule = schedule; self.prompt = prompt
        self.enabled = enabled; self.cwd = cwd; self.model = model
        self.lastRunAt = lastRunAt; self.lastThreadId = lastThreadId
    }
}

/// Parse a schedule string into a fire interval in seconds (nil = manual-only).
/// `public` so the #6 cron migration (in codexd) can reuse the exact mapping
/// instead of duplicating it.
public func automationIntervalSeconds(_ schedule: String) -> Int64? {
    switch schedule.lowercased() {
    case "hourly": return 3600
    case "daily": return 86400
    case "weekly": return 604800
    case "manual", "": return nil
    default: return Int64(schedule.trimmingCharacters(in: .whitespaces))
    }
}

/// JSON-file-backed automations store (one per host).
public actor AutomationStore {
    private let path: String
    private var items: [Automation] = []

    public init(codexHome: String) {
        self.path = codexHome + "/automations.json"
        if let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let a = try? JSONDecoder().decode([Automation].self, from: d) { items = a }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) {
            try? d.write(to: URL(fileURLWithPath: path), options: [.atomic])
        }
    }
    public func list() -> [Automation] { items }
    public func get(_ id: String) -> Automation? { items.first { $0.id == id } }
    public func upsert(_ a: Automation) {
        if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a } else { items.append(a) }
        save()
    }
    public func delete(_ id: String) { items.removeAll { $0.id == id }; save() }
    public func markRan(_ id: String, threadId: String, at: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastRunAt = at; items[i].lastThreadId = threadId; save()
    }
}

/// Process-global handle so the RequestRouter handler and the scheduler share
/// one store without threading it through the (large) router init.
public final class AutomationStoreHolder: @unchecked Sendable {
    public static let shared = AutomationStoreHolder()
    private let lock = NSLock()
    private var _store: AutomationStore?
    public func set(_ s: AutomationStore) { lock.lock(); _store = s; lock.unlock() }
    public func current() -> AutomationStore? { lock.lock(); defer { lock.unlock() }; return _store }
}

/// Fire an automation now: create a fresh thread, bind a worker, start a turn
/// with the automation's prompt. Returns the new threadId.
@discardableResult
public func runAutomation(_ a: Automation, supervisor: SessionSupervisor,
                          store: ThreadStore, defaultCwd: String) async -> String {
    let cfg = SessionConfig(threadId: .generate(),
                            cwd: a.cwd ?? defaultCwd,
                            model: a.model ?? "gpt-5.5")
    _ = try? await store.create(cfg)
    _ = await supervisor.ensureWorker(cfg, onNotification: { _ in }, onServerRequest: { _ in })
    _ = await supervisor.submit(cfg.threadId, .startTurn(input: [TurnInput(text: a.prompt)], model: a.model, turnId: nil))
    return cfg.threadId.raw
}

/// Interval scheduler: ticks periodically and fires any enabled automation
/// whose interval has elapsed since its last run.
public actor AutomationScheduler {
    private let store: AutomationStore
    private let supervisor: SessionSupervisor
    private let threadStore: ThreadStore
    private let defaultCwd: String
    private var task: Task<Void, Never>?

    public init(store: AutomationStore, supervisor: SessionSupervisor,
                threadStore: ThreadStore, defaultCwd: String) {
        self.store = store; self.supervisor = supervisor
        self.threadStore = threadStore; self.defaultCwd = defaultCwd
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [store, supervisor, threadStore, defaultCwd] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                let now = Int64(Date().timeIntervalSince1970)
                for a in await store.list() where a.enabled {
                    guard let interval = automationIntervalSeconds(a.schedule) else { continue }
                    if now - (a.lastRunAt ?? 0) >= interval {
                        let tid = await runAutomation(a, supervisor: supervisor,
                                                      store: threadStore, defaultCwd: defaultCwd)
                        await store.markRan(a.id, threadId: tid, at: now)
                    }
                }
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
}
