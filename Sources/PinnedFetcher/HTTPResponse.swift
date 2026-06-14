import Foundation

/// Pure HTTP/1.1 response parsing. The transport reads raw bytes; this turns
/// them into status + headers + decoded body (Content-Length or chunked). No
/// network, fully testable.
enum HTTPResponse {
    struct Parsed: Equatable {
        var status: Int
        var headers: [String: String]   // lowercased keys; last value wins
        var body: Data
    }

    enum ParseError: Error, Equatable { case malformed }

    /// Parse a complete raw response. Tolerates `\n`-only line endings.
    static func parse(_ raw: Data) throws -> Parsed {
        guard let headerEnd = findHeaderEnd(raw) else { throw ParseError.malformed }
        let headerData = raw.subdata(in: raw.startIndex..<headerEnd.start)
        let body = raw.subdata(in: headerEnd.bodyStart..<raw.endIndex)
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else { throw ParseError.malformed }

        var lines = headerText.split(whereSeparator: { $0 == "\r\n" ? true : false })
        // split on \r\n or \n robustly:
        lines = headerText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n",
                                                                              omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { throw ParseError.malformed }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, statusParts[0].uppercased().hasPrefix("HTTP/"),
              let code = Int(statusParts[1]) else { throw ParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            headers[name] = value   // last value wins (good enough for our needs)
        }

        let decodedBody: Data
        if (headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false) {
            decodedBody = decodeChunked(body)
        } else if let len = headers["content-length"].flatMap({ Int($0) }) {
            decodedBody = body.prefix(max(0, len))
        } else {
            decodedBody = body   // connection-close framing: take what we have
        }
        return Parsed(status: code, headers: headers, body: Data(decodedBody))
    }

    static func isRedirect(_ status: Int) -> Bool { status == 301 || status == 302 || status == 303 || status == 307 || status == 308 }

    // MARK: helpers

    private struct HeaderEnd { let start: Data.Index; let bodyStart: Data.Index }

    /// Find the end of the header block (`\r\n\r\n` or `\n\n`).
    private static func findHeaderEnd(_ d: Data) -> HeaderEnd? {
        let bytes = [UInt8](d)
        var i = 0
        while i < bytes.count {
            if i + 3 < bytes.count, bytes[i] == 0x0d, bytes[i+1] == 0x0a, bytes[i+2] == 0x0d, bytes[i+3] == 0x0a {
                return HeaderEnd(start: d.index(d.startIndex, offsetBy: i),
                                 bodyStart: d.index(d.startIndex, offsetBy: i + 4))
            }
            if i + 1 < bytes.count, bytes[i] == 0x0a, bytes[i+1] == 0x0a {
                return HeaderEnd(start: d.index(d.startIndex, offsetBy: i),
                                 bodyStart: d.index(d.startIndex, offsetBy: i + 2))
            }
            i += 1
        }
        return nil
    }

    /// Decode `chunked` transfer-encoding: hex-length lines, CRLF-delimited.
    static func decodeChunked(_ body: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](body)
        var i = 0
        func readLine() -> String? {
            var s = i
            while s + 1 < bytes.count, !(bytes[s] == 0x0d && bytes[s+1] == 0x0a) { s += 1 }
            guard s + 1 < bytes.count else { return nil }
            let line = String(decoding: bytes[i..<s], as: UTF8.self)
            i = s + 2
            return line
        }
        while i < bytes.count {
            guard let sizeLine = readLine() else { break }
            // chunk-ext after ';' is ignored
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            if size == 0 { break }
            guard i + size <= bytes.count else { break }
            out.append(contentsOf: bytes[i..<(i+size)])
            i += size
            if i + 1 < bytes.count, bytes[i] == 0x0d, bytes[i+1] == 0x0a { i += 2 }   // trailing CRLF
        }
        return out
    }
}
