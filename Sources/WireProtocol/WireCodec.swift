import Foundation
import InfraPrimitives

/// Single-pass JSON-RPC codec. Encodes a typed message **directly** to bytes
/// via `JSONEncoder` (no `JSONValue`→`String` second pass — this is the
/// structural fix for Codex F-2, hardening §4.3). Decoding is size-capped to
/// the configured inbound ceiling (INPUT_TOO_LARGE) and depth-capped before
/// the decoder runs (CWE-674: no unbounded recursion / stack exhaustion from
/// hostile deeply-nested input).
public struct WireCodec: Sendable {
    public let maxInboundBytes: Int
    public let maxDepth: Int

    public init(maxInboundBytes: Int, maxDepth: Int = 512) {
        self.maxInboundBytes = maxInboundBytes
        self.maxDepth = Swift.max(1, maxDepth)
    }
    public init(limits: Limits) {
        self.maxInboundBytes = limits.maxInboundMessageBytes
        self.maxDepth = Swift.max(1, limits.maxJSONNestingDepth)
    }

    public func encode(_ message: JSONRPCMessage) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return try enc.encode(message)
    }

    /// True if the byte stream nests `{`/`[` deeper than `limit`. String
    /// contents (and escaped quotes) are skipped so brackets inside string
    /// literals do not count. O(n), constant memory, never recurses.
    public static func exceedsDepth(_ data: Data, limit: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for b in data {
            if inString {
                if escaped { escaped = false }
                else if b == 0x5C { escaped = true }      // backslash
                else if b == 0x22 { inString = false }    // closing quote
                continue
            }
            switch b {
            case 0x22:                                    // opening quote
                inString = true
            case 0x7B, 0x5B:                              // { or [
                depth += 1
                if depth > limit { return true }
            case 0x7D, 0x5D:                              // } or ]
                if depth > 0 { depth -= 1 }
            default:
                break
            }
        }
        return false
    }

    /// Decode one message. Enforces the inbound size cap, then the nesting
    /// depth cap, then decodes.
    public func decode(_ data: Data) throws -> JSONRPCMessage {
        if data.count > maxInboundBytes {
            throw InputTooLargeError(limit: maxInboundBytes)
        }
        if Self.exceedsDepth(data, limit: maxDepth) {
            throw MaxDepthExceededError(limit: maxDepth)
        }
        return try JSONDecoder().decode(JSONRPCMessage.self, from: data)
    }

    // MARK: stdio JSONL framing (one object per line + '\n')

    public func encodeLine(_ message: JSONRPCMessage) throws -> Data {
        var d = try encode(message)
        d.append(0x0A) // '\n'
        return d
    }

    /// Consume all complete newline-delimited frames from `buffer`, decoding
    /// each. Any trailing partial bytes remain in `buffer` for the next read,
    /// UNLESS that trailing fragment already exceeds `maxInboundBytes` with no
    /// newline in sight — a peer streaming an unbounded line is shed here
    /// (CWE-400) rather than growing `buffer` without bound. Returns one
    /// `Result` per frame (a bad frame never aborts the batch).
    public func decodeFrames(_ buffer: inout Data) -> [Result<JSONRPCMessage, any Error>] {
        var out: [Result<JSONRPCMessage, any Error>] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty { continue }
            do { out.append(.success(try decode(Data(line)))) }
            catch { out.append(.failure(error)) }
        }
        if buffer.count > maxInboundBytes {
            buffer.removeAll(keepingCapacity: false)
            out.append(.failure(InputTooLargeError(limit: maxInboundBytes)))
        }
        return out
    }
}