import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import InfraPrimitives
import Observability

/// `POST /api/upload` — accepts a `multipart/form-data` body with a `file` part
/// (+ optional `threadId` text part), stages it under the media root with a
/// SERVER-generated UUID filename (client filename is never trusted — defeats
/// path traversal), enforces a body-size cap + per-thread quota, sniffs the MIME
/// from content (not the client header), and returns a signed `/media` URL plus
/// the absolute staged path for use as a `localImage` turn-input part.
///
/// Bearer-gated (Authorization header). HTTP, not JSON-RPC, so it bypasses the
/// WS method gate by design — auth is enforced here directly.
enum UploadRoute {
    struct UploadResult: Encodable {
        let blobId: String
        let url: String
        let path: String
        let mime: String
        let name: String
        let status: String
    }

    static func install(on router: Router<BasicRequestContext>,
                        mediaRoot: String,
                        signer: MediaToken.Signer,
                        security: SecurityPolicy,
                        maxUploadBytes: Int,
                        uploadQuotaBytes: Int,
                        log: Log) {
        router.post("api/upload") { request, _ -> Response in
            func header(_ n: String) -> String? { HTTPField.Name(n).flatMap { request.headers[$0] } }

            guard security.httpBearerAccepted(header("Authorization")) else {
                return jsonError(.unauthorized, "unauthorized")
            }
            guard let ct = header("Content-Type"), let boundary = boundary(fromContentType: ct) else {
                return jsonError(.badRequest, "expected multipart/form-data")
            }

            let buffer: ByteBuffer
            do { buffer = try await request.body.collect(upTo: maxUploadBytes) }
            catch { return jsonError(.contentTooLarge, "upload exceeds size limit") }
            var buf = buffer
            let data = Data(buf.readBytes(length: buf.readableBytes) ?? [])

            let parts = parseMultipart(data, boundary: boundary)
            guard let filePart = parts.first(where: { $0.filename != nil }), !filePart.body.isEmpty else {
                return jsonError(.badRequest, "no file part")
            }
            let threadIdRaw = parts.first(where: { $0.name == "threadId" })
                .flatMap { String(data: $0.body, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dir = threadIdRaw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let threadDir = mediaRoot + "/" + (dir.isEmpty ? "shared" : dir)

            // Quota (per thread dir).
            if dirSize(threadDir) + filePart.body.count > uploadQuotaBytes {
                return jsonError(.tooManyRequests, "per-thread upload quota exceeded")
            }

            let (mime, ext) = MIMESniffer.sniff(filePart.body)
            let blobId = UUID().uuidString
            let fileName = "\(blobId).\(ext)"
            let relPath = "\((dir.isEmpty ? "shared" : dir))/\(fileName)"
            let absPath = threadDir + "/" + fileName

            do {
                try FileManager.default.createDirectory(
                    atPath: threadDir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try filePart.body.write(to: URL(fileURLWithPath: absPath), options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: absPath)
            } catch {
                log.error("web gateway: upload stage failed: \(error)")
                return jsonError(.internalServerError, "could not stage upload")
            }

            guard let signed = signer.sign(relPath: relPath) else {
                return jsonError(.internalServerError, "sign failed")
            }
            let result = UploadResult(blobId: blobId, url: "/media/\(signed)", path: absPath,
                                      mime: mime, name: filePart.filename ?? fileName, status: "ready")
            let json = (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
            var headers = HTTPFields()
            if let n = HTTPField.Name("Content-Type") { headers[n] = "application/json" }
            return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: json)))
        }
    }

    // MARK: multipart (byte-level — never round-trips binary through String)

    struct Part { var name: String?; var filename: String?; var contentType: String?; var body: Data }

    static func boundary(fromContentType ct: String) -> String? {
        guard let r = ct.range(of: "boundary=") else { return nil }
        var b = String(ct[r.upperBound...])
        if let semi = b.firstIndex(of: ";") { b = String(b[..<semi]) }
        b = b.trimmingCharacters(in: .whitespaces)
        if b.hasPrefix("\"") && b.hasSuffix("\"") && b.count >= 2 { b = String(b.dropFirst().dropLast()) }
        return b.isEmpty ? nil : b
    }

    static func parseMultipart(_ data: Data, boundary: String) -> [Part] {
        let delim = Data(("--" + boundary).utf8)
        let crlf = Data("\r\n".utf8)
        let headerSep = Data("\r\n\r\n".utf8)
        var positions: [Int] = []
        var search = data.startIndex
        while let r = data.range(of: delim, in: search..<data.endIndex) {
            positions.append(r.lowerBound)
            search = r.upperBound
        }
        guard positions.count >= 2 else { return [] }
        var parts: [Part] = []
        for i in 0..<(positions.count - 1) {
            let start = positions[i] + delim.count
            let end = positions[i + 1]
            guard start <= end else { continue }
            var sub = data.subdata(in: start..<end)
            if sub.starts(with: Data("--".utf8)) { continue }       // closing boundary
            if sub.starts(with: crlf) { sub = sub.subdata(in: 2..<sub.count) }
            guard let sep = sub.range(of: headerSep) else { continue }
            let headerStr = String(data: sub.subdata(in: 0..<sep.lowerBound), encoding: .utf8) ?? ""
            var body = sub.subdata(in: sep.upperBound..<sub.count)
            if body.count >= 2, body.suffix(2) == crlf { body = body.subdata(in: 0..<(body.count - 2)) }
            var name: String?, filename: String?, ctype: String?
            for line in headerStr.components(separatedBy: "\r\n") {
                let low = line.lowercased()
                if low.hasPrefix("content-disposition:") {
                    name = param(line, "name"); filename = param(line, "filename")
                } else if low.hasPrefix("content-type:") {
                    ctype = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
                }
            }
            parts.append(Part(name: name, filename: filename, contentType: ctype, body: body))
        }
        return parts
    }

    static func param(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func dirSize(_ path: String) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return 0 }
        return items.reduce(0) { acc, n in
            acc + (((try? fm.attributesOfItem(atPath: path + "/" + n))?[.size] as? Int) ?? 0)
        }
    }

    static func jsonError(_ status: HTTPResponse.Status, _ msg: String) -> Response {
        var headers = HTTPFields()
        if let n = HTTPField.Name("Content-Type") { headers[n] = "application/json" }
        let escaped = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let body = Data("{\"error\":\"\(escaped)\"}".utf8)
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: body)))
    }
}

/// Content-based MIME sniffing (magic bytes). Never trust the client's
/// Content-Type for a stored/served file.
enum MIMESniffer {
    static func sniff(_ d: Data) -> (mime: String, ext: String) {
        let b = [UInt8](d.prefix(16))
        func at(_ off: Int, _ sig: [UInt8]) -> Bool {
            b.count >= off + sig.count && Array(b[off..<off + sig.count]) == sig
        }
        if at(0, [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
        if at(0, [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if at(0, [0x47, 0x49, 0x46, 0x38]) { return ("image/gif", "gif") }
        if at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50]) { return ("image/webp", "webp") }
        if at(0, [0x25, 0x50, 0x44, 0x46]) { return ("application/pdf", "pdf") }
        if at(4, [0x66, 0x74, 0x79, 0x70]) { return ("video/mp4", "mp4") }
        if at(0, [0x1A, 0x45, 0xDF, 0xA3]) { return ("video/webm", "webm") }
        if at(0, [0x49, 0x44, 0x33]) || at(0, [0xFF, 0xFB]) { return ("audio/mpeg", "mp3") }
        if at(0, [0x4F, 0x67, 0x67, 0x53]) { return ("audio/ogg", "ogg") }
        if at(0, [0x50, 0x4B, 0x03, 0x04]) { return ("application/zip", "zip") }   // also docx/xlsx
        if String(data: d.prefix(2048), encoding: .utf8) != nil { return ("text/plain", "txt") }
        return ("application/octet-stream", "bin")
    }
}
