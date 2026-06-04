import Foundation

/// Durable JSON-file backing for the ledger so QUEUED tasks survive a daemon
/// crash/restart (the poller's `recover()` reloads them and keeps driving).
/// Whole-file atomic replace — the task set is small (one process's in-flight
/// media jobs), so a full rewrite per change is cheap and avoids partial writes.
public actor FileMediaStore: MediaStore {
    private let path: String

    public init(directory: String) {
        self.path = directory + "/media-tasks.json"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
    }

    public func load() -> [MediaTask] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([MediaTask].self, from: data)) ?? []
    }

    public func save(_ tasks: [MediaTask]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        // Atomic replace: write a temp then rename, so a crash mid-write never
        // leaves a half-written ledger that fails to decode on restart.
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            _ = try? FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
            // replaceItemAt removes the source on success; if the dest didn't
            // exist it may leave tmp — best-effort move as a fallback.
            if FileManager.default.fileExists(atPath: tmp) {
                try? FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: tmp, toPath: path)
            }
        } catch {
            // Best-effort durability; a failed persist must not crash the poller.
        }
    }
}
