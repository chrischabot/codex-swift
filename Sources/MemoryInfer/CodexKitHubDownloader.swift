#if CODEXKIT_MLX
import Foundation
import MLXLMCommon

/// Minimal HuggingFace Hub Downloader for the Memory Wiki's MLXLocalProvider.
/// Uses `/usr/bin/curl` to fetch repo snapshots into the standard HuggingFace
/// cache layout at `~/.cache/huggingface/hub/<org>/<model>/snapshots/<revision>/`.
///
/// Scope limits, deliberately:
/// - Anonymous public reads only (no token plumbing). Private repos require
///   the user to drop `huggingface-cli login` artifacts into place before
///   first run.
/// - `useLatest = false` always hits the cache when present; `true` re-resolves
///   the `main` revision via the Hub API.
/// - Pattern matching is glob-style and only honoured against the file's
///   suffix (`*.safetensors`, `*.json`, `*.jinja`, etc.).
///
/// The full-featured `HuggingFace.HubClient` from swift-huggingface is the
/// long-term replacement (the upstream `MLXHuggingFaceMacros` generates the
/// bridge automatically). This implementation is the dependency-free fallback
/// that ships in the CodexKit binary today.
public struct CodexKitHubDownloader: Downloader {
    public let endpoint: URL
    public let cacheRoot: URL

    public init(endpoint: URL = URL(string: "https://huggingface.co")!,
                cacheRoot: URL? = nil) {
        self.endpoint = endpoint
        if let cacheRoot {
            self.cacheRoot = cacheRoot
        } else {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
            self.cacheRoot = URL(fileURLWithPath: home)
                .appendingPathComponent(".cache/huggingface/hub")
        }
    }

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let parts = id.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {
            throw NSError(domain: "CodexKitHubDownloader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "expected org/model id, got \"\(id)\""])
        }
        let rev = (revision?.isEmpty == false) ? revision! : "main"
        let snapshotDir = cacheRoot
            .appendingPathComponent("\(parts[0])/\(parts[1])/snapshots/\(rev)")

        try FileManager.default.createDirectory(at: snapshotDir,
                                                withIntermediateDirectories: true)

        // List files we already have so an interrupted run resumes cleanly.
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: snapshotDir.path)) ?? []
        let cached = Set(existing)

        // Resolve the file list via the Hub API.
        let files = try await listRepoFiles(id: id, revision: rev)
        let filtered = files.filter { name in
            patterns.isEmpty || patterns.contains(where: { Self.matches(glob: $0, name: name) })
        }
        var total: Int64 = 0
        var done: Int64 = 0
        for name in filtered {
            if cached.contains(name) { continue }
            total += 1
        }
        if total == 0 { return snapshotDir }
        let progress = Progress(totalUnitCount: total)
        progressHandler(progress)

        for name in filtered {
            if cached.contains(name) && !useLatest { continue }
            let dest = snapshotDir.appendingPathComponent(name)
            try await downloadOne(repoID: id, revision: rev, file: name, dest: dest)
            done += 1
            progress.completedUnitCount = done
            progressHandler(progress)
        }
        return snapshotDir
    }

    // MARK: - private

    func listRepoFiles(id: String, revision: String) async throws -> [String] {
        // /api/models/<id>/tree/<revision> returns a JSON array of {path, type, …}
        let url = endpoint.appendingPathComponent("api/models/\(id)/tree/\(revision)")
        let (data, _) = try await runCurl(args: [
            "-sSL", url.absoluteString,
            "--max-time", "60", "-A", "CodexKit-Memory/1.0",
        ])
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return arr.compactMap { $0["path"] as? String }
    }

    func downloadOne(repoID: String, revision: String, file: String, dest: URL) async throws {
        let url = endpoint
            .appendingPathComponent("\(repoID)/resolve/\(revision)/\(file)")
        _ = try await runCurl(args: [
            "-sSL", url.absoluteString,
            "--max-time", "1800", "-A", "CodexKit-Memory/1.0",
            "-o", dest.path,
        ])
    }

    static func matches(glob: String, name: String) -> Bool {
        guard glob.contains("*") else { return glob == name }
        let parts = glob.split(separator: "*", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2 else { return false }
        var rest = name
        if let first = parts.first, !first.isEmpty {
            guard rest.hasPrefix(first) else { return false }
            rest = String(rest.dropFirst(first.count))
        }
        if let last = parts.last, !last.isEmpty {
            guard rest.hasSuffix(last) else { return false }
            rest = String(rest.dropLast(last.count))
        }
        return true
    }

    func runCurl(args: [String]) async throws -> (Data, Int32) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = args
            let out = Pipe(); p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch {
                cont.resume(throwing: error); return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: (data, p.terminationStatus))
        }
    }
}

/// Stand-in `TokenizerLoader` that delegates to the JSON-driven tokenizer
/// parser shipped with HuggingFace's `tokenizers` repository. Until the
/// CodexKit build pulls in `swift-transformers` (or wires the
/// `@HuggingFaceIntegration` macro), this loader throws a structured error
/// pointing the user at the correct integration step.
///
/// The MLXLocalProvider checks `MLXLocalProvider.isAvailable` before calling
/// any of these paths; in environments without a real Tokenizer, the
/// assembler falls back to the remote provider.
public struct CodexKitTokenizerLoader: TokenizerLoader {
    public init() {}

    public func load(from directory: URL) async throws -> any Tokenizer {
        throw NSError(
            domain: "CodexKitTokenizerLoader", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "BYO tokenizer required. Wire MLXHuggingFace + swift-transformers and " +
                "register your tokenizer loader by replacing CodexKitTokenizerLoader. " +
                "Until then the remote/mock inference provider is the only path."])
    }
}
#endif
