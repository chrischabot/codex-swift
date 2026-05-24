import Foundation
import WireProtocol
import InfraPrimitives

/// Serializes stdout writes for the stdio transport. An actor is async-safe
/// (NSLock.lock/unlock is unavailable from async contexts under Swift 6).
actor StdoutWriter {
    func write(_ data: Data) {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

/// stdio JSONL transport (Codex default `stdio://`). One JSON object per line
/// in, one per line out. Portable: stdin is read on a blocking background
/// thread with newline buffering (no AsyncBytes platform dependency). The
/// loopback TCP/UDS WebSocket listeners are the additional production
/// transports covered by STATUS.md.
public final class StdioConnection: ClientConnection, @unchecked Sendable {
    private let codec: WireCodec
    private let out = StdoutWriter()
    private let inStream: AsyncStream<JSONRPCMessage>
    private let inCont: AsyncStream<JSONRPCMessage>.Continuation

    public init(limits: Limits = Limits()) {
        self.codec = WireCodec(limits: limits.clamped())
        (inStream, inCont) = AsyncStream<JSONRPCMessage>.makeStream()
    }

    /// Begin reading stdin. Bad frames are skipped (never crash the daemon).
    public func startReading() {
        let cont = inCont
        let codec = codec
        let thread = Thread {
            var buffer = Data()
            let handle = FileHandle.standardInput
            while true {
                let chunk = handle.availableData     // blocks; empty == EOF
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.firstIndex(of: 0x0A) == nil
                    && buffer.count > codec.maxInboundBytes {
                    buffer.removeAll(keepingCapacity: false)
                    continue
                }
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if line.isEmpty { continue }
                    if let m = try? codec.decode(line) { cont.yield(m) }
                }
            }
            cont.finish()
        }
        thread.stackSize = 1 << 20
        thread.name = "ai.igent.codexkit.stdin"
        thread.start()
    }

    public func incoming() -> AsyncStream<JSONRPCMessage> { inStream }

    public func send(_ message: JSONRPCMessage) async {
        guard var data = try? codec.encode(message) else { return }
        data.append(0x0A)
        await out.write(data)
    }
}
