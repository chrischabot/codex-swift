import Foundation
import Dispatch
import Darwin
import WireProtocol

actor FileWatchManager {
    private struct WatchError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private struct WatchKey: Hashable {
        var connection: ObjectIdentifier
        var watchId: String
    }

    private struct WatchEntry {
        var task: Task<Void, Never>
    }

    private final class NativeWatchSignal: @unchecked Sendable {
        private let queue: DispatchQueue
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var sources: [any DispatchSourceFileSystemObject] = []

        init(path: String) {
            self.queue = DispatchQueue(label: "codexkit.fs-watch." + UUID().uuidString)
            refresh(path: path)
        }

        var hasNativeSources: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !sources.isEmpty
        }

        func refresh(path: String) {
            let paths = Self.pathsToObserve(path: path)
            lock.lock()
            cancelLocked(finish: false)
            for observedPath in paths {
                let fd = open(observedPath, O_EVTONLY)
                if fd < 0 { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                    queue: queue)
                source.setEventHandler { [semaphore] in
                    semaphore.signal()
                }
                source.setCancelHandler {
                    close(fd)
                }
                sources.append(source)
                source.resume()
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelLocked(finish: true)
            lock.unlock()
            semaphore.signal()
        }

        func waitForNativeEvent(timeoutMs: Int) {
            _ = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
        }

        private func cancelLocked(finish: Bool) {
            let oldSources = sources
            sources.removeAll()
            for source in oldSources {
                source.setEventHandler {}
                source.cancel()
            }
            if finish { semaphore.signal() }
        }

        private static func pathsToObserve(path: String) -> [String] {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if exists, isDir.boolValue {
                let children = ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
                    .map { URL(fileURLWithPath: path)
                        .appendingPathComponent($0)
                        .standardizedFileURL.path }
                return ([path] + children).deduplicated()
            }
            if exists {
                return parent == path ? [path] : [path, parent]
            }
            return [parent]
        }
    }

    private struct Fingerprint: Equatable, Sendable {
        var exists: Bool
        var isDirectory: Bool
        var isFile: Bool
        var isSymlink: Bool
        var modifiedNs: Int64
        var size: Int64
    }

    private var entries: [WatchKey: WatchEntry] = [:]

    func watch(conn: any ClientConnection, watchId: String, path: String) throws -> JSONValue {
        let key = WatchKey(connection: ObjectIdentifier(conn as AnyObject), watchId: watchId)
        guard entries[key] == nil else {
            throw WatchError(message: "watchId already exists: \(watchId)")
        }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let initialSnapshot = Self.snapshot(path: standardizedPath)
        let task = Task.detached(priority: .utility) {
            await Self.watchLoop(conn: conn, watchId: watchId,
                                 path: standardizedPath, initialSnapshot: initialSnapshot)
        }
        entries[key] = WatchEntry(task: task)
        return .object(["path": .string(standardizedPath)])
    }

    func unwatch(conn: any ClientConnection, watchId: String) async {
        let key = WatchKey(connection: ObjectIdentifier(conn as AnyObject), watchId: watchId)
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.task.cancel()
        await entry.task.value
    }

    func connectionClosed(conn: any ClientConnection) async {
        let id = ObjectIdentifier(conn as AnyObject)
        let owned = entries.filter { $0.key.connection == id }
        for key in owned.keys {
            if let entry = entries.removeValue(forKey: key) {
                entry.task.cancel()
            }
        }
        for entry in owned.values {
            await entry.task.value
        }
    }

    private static func watchLoop(conn: any ClientConnection,
                                  watchId: String,
                                  path: String,
                                  initialSnapshot: [String: Fingerprint]) async {
        let signal = NativeWatchSignal(path: path)
        defer { signal.cancel() }
        var previous = initialSnapshot
        while !Task.isCancelled {
            if signal.hasNativeSources {
                signal.waitForNativeEvent(timeoutMs: 150)
            } else {
                try? await Task.sleep(for: .milliseconds(150))
            }
            if Task.isCancelled { break }
            let current = snapshot(path: path)
            let changed = changedPaths(previous: previous, current: current)
            previous = current
            signal.refresh(path: path)
            if changed.isEmpty { continue }
            if Task.isCancelled { break }
            await conn.send(.notification(JSONRPCNotification(
                method: "fs/changed",
                params: .object([
                    "watchId": .string(watchId),
                    "changedPaths": .array(changed.map(JSONValue.string)),
                ]))))
        }
    }

    private static func changedPaths(previous: [String: Fingerprint],
                                     current: [String: Fingerprint]) -> [String] {
        let keys = Set(previous.keys).union(current.keys)
        return keys.compactMap { key in
            if previous[key] != current[key] { return key }
            return nil
        }.sorted()
    }

    private static func snapshot(path: String) -> [String: Fingerprint] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        if exists, isDir.boolValue {
            var out: [String: Fingerprint] = [:]
            if let root = fingerprint(path: path) { out[path] = root }
            let children = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            for child in children {
                let childPath = URL(fileURLWithPath: path)
                    .appendingPathComponent(child).standardizedFileURL.path
                if let fp = fingerprint(path: childPath) {
                    out[childPath] = fp
                }
            }
            return out
        }
        if let fp = fingerprint(path: path) {
            return [path: fp]
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var out: [String: Fingerprint] = [
            path: Fingerprint(exists: false, isDirectory: false, isFile: false,
                              isSymlink: false, modifiedNs: 0, size: 0),
        ]
        if let parentFp = fingerprint(path: parent) {
            out[parent] = parentFp
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
            isFile: type == .typeRegular,
            isSymlink: type == .typeSymbolicLink,
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
