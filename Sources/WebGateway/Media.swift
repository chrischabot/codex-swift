import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import InfraPrimitives
import Observability

/// `GET /media/:token` — serves a single file addressed by an unforgeable,
/// time-limited `MediaToken` (the rel-path is signed INTO the token, so there
/// is no path in the URL and no per-connection session needed). Supports HTTP
/// `Range`/206 so `<video>`/`<audio>` can seek. Files are resolved strictly
/// under `mediaRoot`.
///
/// Streaming uses a Foundation `FileHandle` in 128 KiB chunks with backpressure
/// (bounded memory). NOTE: the chunk reads are synchronous on the event loop —
/// acceptable for local media in v1; revisit with NIOFileSystem if it becomes a
/// throughput bottleneck.
enum MediaRoute {
    static func install(on router: Router<BasicRequestContext>,
                        mediaRoot: String,
                        signer: MediaToken.Signer,
                        log: Log) {
        // Resolve symlinks on the root once (e.g. macOS /tmp → /private/tmp) so
        // the containment check below compares fully-resolved paths.
        let root = URL(fileURLWithPath: mediaRoot).resolvingSymlinksInPath().path
        router.get("media/:token") { request, context -> Response in
            guard let token = context.parameters.get("token"),
                  let relPath = signer.verify(token) else {
                return Response(status: .forbidden)
            }
            let abs = URL(fileURLWithPath: root + "/" + relPath).resolvingSymlinksInPath().path
            guard abs == root || abs.hasPrefix(root + "/") else {
                log.error("web gateway: media path escapes root: \(relPath)")
                return Response(status: .forbidden)
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), !isDir.boolValue else {
                return Response(status: .notFound)
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: abs))?[.size] as? Int) ?? 0

            // Range (single range only; clamp to valid bounds).
            var status: HTTPResponse.Status = .ok
            var lower = 0
            var upper = max(0, size - 1)
            if size > 0,
               let rangeHeader = HTTPField.Name("Range").flatMap({ request.headers[$0] }),
               rangeHeader.hasPrefix("bytes=") {
                let parts = rangeHeader.dropFirst("bytes=".count)
                    .split(separator: "-", omittingEmptySubsequences: false)
                if let first = parts.first, let s = Int(first) {
                    lower = min(max(0, s), size - 1)
                    if parts.count > 1, let e = Int(parts[1]), e >= lower { upper = min(e, size - 1) }
                    status = .partialContent
                }
            }
            let length = (size == 0) ? 0 : (upper - lower + 1)
            let mime = MediaMime.type(forPath: abs)

            var headers = HTTPFields()
            func set(_ name: String, _ value: String) { if let n = HTTPField.Name(name) { headers[n] = value } }
            set("Content-Type", mime)
            set("Accept-Ranges", "bytes")
            set("Cache-Control", "private, max-age=60")
            set("Content-Disposition", MediaMime.isInline(mime) ? "inline" : "attachment")
            if status == .partialContent { set("Content-Range", "bytes \(lower)-\(upper)/\(size)") }

            let startOffset = lower
            let filePath = abs
            let body = ResponseBody(contentLength: length) { writer in
                let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
                defer { try? fh.close() }
                if startOffset > 0 { try fh.seek(toOffset: UInt64(startOffset)) }
                var remaining = length
                let chunk = 128 * 1024
                while remaining > 0 {
                    let toRead = min(chunk, remaining)
                    guard let data = try fh.read(upToCount: toRead), !data.isEmpty else { break }
                    try await writer.write(ByteBuffer(bytes: data))
                    remaining -= data.count
                }
            }
            return Response(status: status, headers: headers, body: body)
        }
    }
}
