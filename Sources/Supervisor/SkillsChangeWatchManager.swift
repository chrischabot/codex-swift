import Foundation
import WireProtocol
import ProtocolModel

actor SkillsChangeWatchManager {
    private struct WatchKey: Hashable {
        var connection: ObjectIdentifier
        var threadId: ThreadId
    }

    private struct Fingerprint: Equatable, Sendable {
        var exists: Bool
        var isDirectory: Bool
        var modifiedNs: Int64
        var size: Int64
    }

    private struct WatchEntry {
        var task: Task<Void, Never>
    }

    private var entries: [WatchKey: WatchEntry] = [:]

    func watch(conn: any ClientConnection, threadId: ThreadId, roots: [String]) {
        let key = WatchKey(connection: ObjectIdentifier(conn as AnyObject),
                           threadId: threadId)
        entries.removeValue(forKey: key)?.task.cancel()
        let standardizedRoots = roots
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .deduplicated()
        let initialSnapshot = Self.snapshot(roots: standardizedRoots)
        let task = Task.detached(priority: .utility) {
            await Self.watchLoop(conn: conn, roots: standardizedRoots,
                                 initialSnapshot: initialSnapshot)
        }
        entries[key] = WatchEntry(task: task)
    }

    func unwatch(conn: any ClientConnection, threadId: ThreadId) async {
        let key = WatchKey(connection: ObjectIdentifier(conn as AnyObject),
                           threadId: threadId)
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.task.cancel()
        await entry.task.value
    }

    func connectionClosed(conn: any ClientConnection) async {
        let connection = ObjectIdentifier(conn as AnyObject)
        let owned = entries.filter { $0.key.connection == connection }
        for key in owned.keys {
            entries.removeValue(forKey: key)?.task.cancel()
        }
        for entry in owned.values {
            await entry.task.value
        }
    }

    private static func watchLoop(conn: any ClientConnection,
                                  roots: [String],
                                  initialSnapshot: [String: Fingerprint]) async {
        var previous = initialSnapshot
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { break }
            let current = snapshot(roots: roots)
            guard current != previous else { continue }
            previous = current
            await conn.send(ServerNotification.skillsChanged.toMessage())
        }
    }

    private static func snapshot(roots: [String]) -> [String: Fingerprint] {
        var out: [String: Fingerprint] = [:]
        for root in roots {
            if let fp = fingerprint(path: root) {
                out[root] = fp
            } else {
                out[root] = Fingerprint(exists: false, isDirectory: false,
                                        modifiedNs: 0, size: 0)
                if let parentFp = fingerprint(
                    path: URL(fileURLWithPath: root).deletingLastPathComponent().path) {
                    out["\(root)#parent"] = parentFp
                }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else {
                continue
            }
            var count = 0
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                if let fp = fingerprint(path: path) {
                    out[path] = fp
                }
                count += 1
                if count >= 2_000 { break }
            }
        }
        return out
    }

    private static func fingerprint(path: String) -> Fingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let type = attrs[.type] as? FileAttributeType
        let modified = attrs[.modificationDate] as? Date
        let seconds = modified?.timeIntervalSince1970 ?? 0
        return Fingerprint(
            exists: true,
            isDirectory: type == .typeDirectory,
            modifiedNs: Int64(seconds * 1_000_000_000),
            size: attrs[.size] as? Int64 ?? Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0))
    }
}

private extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in self where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}
