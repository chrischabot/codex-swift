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
        // `.atomic` writes to a temp file then renames into place — atomic,
        // correct for a non-existent destination (first save), and never leaves
        // a half-written ledger that fails to decode on restart. A failed write
        // is best-effort (leaves the prior file intact) and must not crash the
        // poller.
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
