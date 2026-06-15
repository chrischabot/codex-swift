import Foundation
import InfraPrimitives   // Hashing.sha256

/// The `statOnly` worker: a bounded, kind-agnostic stat of a data/text file. Runs
/// in the sandboxed child (read-only, no-network, rlimit-capped), but is a pure
/// library function so it is unit-testable directly with crafted inputs.
///
/// The defining principle (same as the dataset profiler it sandboxes): NEVER load
/// the whole file — read at most `readCap` bytes, report an exact line count only
/// when the whole file fit, and return a row- and per-line-capped sample so a
/// hostile file can neither exhaust memory nor exfiltrate more than the cap.
public enum MediaStatter {
    /// Absolute ceiling on the read (defense in depth, independent of caps): 256 KiB.
    public static let defaultReadCap = 256 * 1024
    /// Absolute ceiling on the returned sample rows, and per-row length.
    public static let hardSampleCap = 20
    public static let maxLineChars = 500

    /// Stat `path`. Throws `MediaExtractError` on any failure (so the child maps it
    /// to a typed `{"error":…}` — a malicious file never produces an exception that
    /// escapes into the parent).
    public static func stat(path: String,
                            caps rawCaps: MediaDecodeCaps = MediaDecodeCaps(),
                            readCap: Int = defaultReadCap,
                            rowCap: Int = hardSampleCap) throws -> MediaStatResult {
        let caps = rawCaps.clamped()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              fm.isReadableFile(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue else {
            throw MediaExtractError.unreadable
        }
        guard size <= caps.maxInputBytes else { throw MediaExtractError.oversizeInput }
        guard let fh = FileHandle(forReadingAtPath: path) else { throw MediaExtractError.unreadable }
        defer { try? fh.close() }
        // Bounded read — never loads a whole file. Read cap is clamped to a sane
        // floor so a degenerate caps value can't disable sampling entirely.
        let bound = max(4096, min(readCap, caps.maxInputBytes))
        let data = (try? fh.read(upToCount: bound)) ?? Data()
        let truncated = data.count < size

        // Normalize CRLF/CR → LF first: Swift treats "\r\n" as a SINGLE Character,
        // so a raw split on "\n" miscounts every Windows-authored CSV as one line.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // drop the single trailing empty from a final newline
        let cap = min(max(1, rowCap), hardSampleCap)
        let sample = lines.prefix(cap).map { String($0.prefix(maxLineChars)) }
        let lineCount = truncated ? -1 : lines.count   // exact only when the whole file fit
        let sha = Hashing.sha256(Array(data)).map { String(format: "%02x", $0) }.joined()
        return MediaStatResult(byteSize: size, lineCount: lineCount, sample: sample,
                               sha256: sha, truncated: truncated)
    }
}
